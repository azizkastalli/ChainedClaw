#!/bin/bash
#
# Tear down a workspace for a host.
#
# Three atomic actions:
#   1. docker stop && docker rm  (as AGENT_USER via rootless)
#   2. Remove the sshd Match User block from /etc/ssh/sshd_config
#   3. Flush the UID-keyed egress filter (if present)
#
# Does NOT:
#   - touch project_paths (your files are untouched)
#   - delete AGENT_USER (cheap to leave; reused on next workspace_up)
#   - remove rootless Docker itself (may be used by other hosts)
#
# authorized_keys cleanup is handled by scripts/ssh_key/remove.sh.
#
# Usage: workspace_down.sh <host-name>
#
set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

if [ "$EUID" -ne 0 ]; then
    log_error "Must run as root (sudo)"
    exit 1
fi

PURGE="${2:-}"   # pass --purge to also remove AGENT_USER and rootless Docker

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENV_FILE="$PROJECT_ROOT/.env"
CONFIG_JSON="$PROJECT_ROOT/config.json"

if [ ! -f "$ENV_FILE" ]; then
    log_error ".env not found at $ENV_FILE"
    exit 1
fi
source "$ENV_FILE"

if [ -z "${1:-}" ]; then
    echo "Usage: $0 <host-name>"
    exit 1
fi
HOST_NAME="$1"

ISOLATION="container"
if [ -f "$CONFIG_JSON" ] && command -v jq &>/dev/null; then
    _iso=$(jq -r --arg name "$HOST_NAME" \
        '.ssh_hosts[] | select(.name == $name) | .isolation // "container"' \
        "$CONFIG_JSON" 2>/dev/null)
    [ -n "$_iso" ] && [ "$_iso" != "null" ] && ISOLATION="$_iso"
fi

if [ "$ISOLATION" = "restricted_key" ]; then
    echo "=== Teardown: restricted_key mode for '$HOST_NAME' ==="
    if id "$AGENT_USER" &>/dev/null; then
        pkill -u "$AGENT_USER" 2>/dev/null || true
        userdel -r "$AGENT_USER" 2>/dev/null || true
        log_info "Removed user $AGENT_USER"
    fi
    log_info "Teardown complete"
    exit 0
fi

CONTAINER_NAME="workspace-${HOST_NAME}"

echo "=== Tearing down workspace for '$HOST_NAME' ==="

# 1. Stop and remove the container (via rootless Docker as AGENT_USER)
if id "$AGENT_USER" &>/dev/null; then
    AGENT_UID=$(id -u "$AGENT_USER")
    DOCKER_SOCKET_PATH="/run/user/$AGENT_UID/docker.sock"
    PROXY_SOCKET_PATH="/run/user/$AGENT_UID/docker-proxy.sock"

    # Stop the Docker socket proxy if it is running.
    if pkill -u "$AGENT_USER" -f 'openclaw-docker-proxy' 2>/dev/null; then
        log_info "  Docker proxy stopped"
    fi
    rm -f "$PROXY_SOCKET_PATH"
    if [ -S "$DOCKER_SOCKET_PATH" ]; then
        log_info "[1/3] Stopping container $CONTAINER_NAME..."
        su - "$AGENT_USER" -c \
            "DOCKER_HOST=unix://$DOCKER_SOCKET_PATH PATH=\$HOME/bin:\$PATH docker rm -f $CONTAINER_NAME" \
            >/dev/null 2>&1 && log_info "  Removed $CONTAINER_NAME" \
            || log_info "  $CONTAINER_NAME not running"
    else
        log_warn "[1/3] Rootless Docker socket not found; skipping container removal"
    fi
else
    log_warn "[1/3] $AGENT_USER does not exist; skipping container removal"
fi

# 2. Remove sshd Match block
log_info "[2/3] Removing sshd Match block..."
_removed_any=false
for marker in "Dev-Agent Workspace Configuration" "Dev-Agent Chroot Configuration"; do
    if grep -q "# BEGIN $marker" /etc/ssh/sshd_config 2>/dev/null; then
        sed -i "/# BEGIN $marker/,/# END $marker/d" /etc/ssh/sshd_config
        log_info "  Removed: $marker"
        _removed_any=true
    fi
done
$_removed_any || log_info "  No Match block found"

# 3. Flush egress filter if present
if [ -f "$SCRIPT_DIR/egress_filter.sh" ]; then
    log_info "[3/4] Flushing egress filter (if active)..."
    bash "$SCRIPT_DIR/egress_filter.sh" "$HOST_NAME" --flush 2>/dev/null || true
fi

# 4. Remove ACLs granted to AGENT_USER on this host's project_paths
log_info "[4/4] Removing ACLs on project_paths..."
if command -v setfacl &>/dev/null && [ -f "$CONFIG_JSON" ] && command -v jq &>/dev/null; then
    while IFS= read -r path; do
        [ -z "$path" ] && continue
        if [ -d "$path" ]; then
            setfacl -R -x "u:$AGENT_USER" "$path" 2>/dev/null && \
                log_info "  ACL removed: $path" || true
            # Remove traverse ACL entries on parent dirs only if no longer needed.
            _parent="$path"
            while [ "$_parent" != "/" ]; do
                _parent="$(dirname "$_parent")"
                setfacl -x "u:$AGENT_USER" "$_parent" 2>/dev/null || true
            done
        fi
    done < <(jq -r --arg name "$HOST_NAME" \
        '.ssh_hosts[] | select(.name == $name) | .project_paths[]' "$CONFIG_JSON" 2>/dev/null)
else
    log_warn "  skipped (setfacl or jq not available)"
fi

# -- Purge: remove AGENT_USER, rootless Docker, subuid/subgid (--purge only) ---
if [ "$PURGE" = "--purge" ]; then
    echo ""
    log_info "=== Purging $AGENT_USER from host ==="
    if id "$AGENT_USER" &>/dev/null; then
        AGENT_UID=$(id -u "$AGENT_USER")
        DOCKER_SOCKET="/run/user/$AGENT_UID/docker.sock"

        # Stop rootless dockerd gracefully, then force-kill any remaining processes.
        su - "$AGENT_USER" -c "dockerd-rootless-stop.sh" 2>/dev/null || true
        sleep 1
        pkill -u "$AGENT_USER" 2>/dev/null || true
        sleep 1
        # Force-kill anything still alive (dockerd can be stubborn).
        pkill -9 -u "$AGENT_USER" 2>/dev/null || true
        sleep 1

        loginctl disable-linger "$AGENT_USER" 2>/dev/null || true

        if userdel -r "$AGENT_USER"; then
            log_info "  Removed user $AGENT_USER and home directory"
        else
            log_error "  userdel failed — processes may still be running as $AGENT_USER"
            log_error "  Running processes:"
            ps -u "$AGENT_USER" -o pid,comm 2>/dev/null || true
            log_error "  Kill them manually then re-run: sudo userdel -r $AGENT_USER"
            exit 1
        fi

        sed -i "/^${AGENT_USER}:/d" /etc/subuid 2>/dev/null || true
        sed -i "/^${AGENT_USER}:/d" /etc/subgid 2>/dev/null || true
        log_info "  Removed subuid/subgid entries"

        rm -rf "/run/user/$AGENT_UID" 2>/dev/null || true
        log_info "  Removed runtime dir"
    else
        log_info "  $AGENT_USER does not exist, nothing to purge"
    fi
fi

echo ""
log_info "=== Teardown complete for '$HOST_NAME' ==="
echo "  Your project_paths are untouched."
[ "$PURGE" != "--purge" ] && echo "  $AGENT_USER user kept (run with --purge to remove it)."
echo "  To remove the agent's authorized_keys line: make key-remove HOST=$HOST_NAME"
echo "  Then: systemctl reload sshd"
