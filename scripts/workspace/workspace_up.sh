#!/bin/bash
#
# Provision a workspace container for a host defined in config.json.
# Replaces the old chroot-jail setup with a rootless-Docker container.
#
# What this script does (all idempotent):
#   1. Creates AGENT_USER as a regular host user (no chroot, no group hacks).
#   2. Installs and starts rootless Docker for AGENT_USER.
#   3. Builds the agents-workspace image from agents/workspace/Dockerfile.
#   4. Runs a long-lived container per host, with project_paths bind-mounted
#      RW and forward_ports published to 127.0.0.1 on the host.
#   5. Optionally bind-mounts the rootless Docker socket into the container
#      (docker_access: true — enables Docker-in-Docker for the agent).
#   6. Installs /usr/local/bin/openclaw-session-entry (ForceCommand target).
#   7. Appends a Match User block to sshd_config enforcing PermitOpen
#      for forward_ports. No ChrootDirectory anywhere.
#   8. Optionally applies the UID-keyed egress filter.
#
# What this script explicitly does NOT do:
#   - chmod anything under project_paths (those stay as the operator set them)
#   - usermod -aG to add AGENT_USER to project-file groups
#   - bind-mount /bin, /lib, /usr/lib, or any host system directory
#   - rm -rf anything outside the workspace Docker state
#
# Usage: workspace_up.sh <host-name>
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

if ! command -v jq &>/dev/null; then
    log_error "jq is required. Install with: apt install jq"
    exit 1
fi

if ! command -v docker &>/dev/null && [ ! -x "/home/${AGENT_USER}/bin/docker" ]; then
    # Docker is needed to build/run the workspace image. The rootless installer
    # below will fetch it if missing, but warn up front.
    log_info "Docker CLI not found on PATH — will be installed by rootless setup."
fi

# ── Read per-host config ───────────────────────────────────────────────────────
ISOLATION=$(jq -r --arg name "$HOST_NAME" \
    '.ssh_hosts[] | select(.name == $name) | .isolation // "container"' \
    "$CONFIG_JSON")
[ -z "$ISOLATION" ] || [ "$ISOLATION" = "null" ] && ISOLATION="container"

if [ "$ISOLATION" = "restricted_key" ]; then
    echo "=== Isolation: restricted_key (no workspace container) ==="
    if ! id "$AGENT_USER" &>/dev/null; then
        useradd -m -s /bin/bash "$AGENT_USER"
        log_info "User $AGENT_USER created"
    else
        log_info "User $AGENT_USER already exists"
    fi
    log_info "Install the SSH key next: make key-add HOST=$HOST_NAME"
    exit 0
fi

if [ "$ISOLATION" != "container" ]; then
    log_error "Unknown isolation mode: '$ISOLATION'"
    log_error "Valid values: container, restricted_key"
    exit 1
fi

PROJECT_PATHS=$(jq -r --arg name "$HOST_NAME" \
    '.ssh_hosts[] | select(.name == $name) | .project_paths[]' \
    "$CONFIG_JSON")
if [ -z "$PROJECT_PATHS" ]; then
    log_error "No project_paths for host '$HOST_NAME' in config.json"
    exit 1
fi

FORWARD_PORTS=$(jq -r --arg name "$HOST_NAME" \
    '.ssh_hosts[] | select(.name == $name) | .forward_ports // [] | .[] | tostring' \
    "$CONFIG_JSON" | tr '\n' ' ' | xargs || true)

DOCKER_ACCESS=$(jq -r --arg name "$HOST_NAME" \
    '.ssh_hosts[] | select(.name == $name) | .docker_access // false' \
    "$CONFIG_JSON")
[ "$DOCKER_ACCESS" = "null" ] && DOCKER_ACCESS="false"

EGRESS_FILTER=$(jq -r --arg name "$HOST_NAME" \
    '.ssh_hosts[] | select(.name == $name) | .egress_filter // .chroot_egress_filter // false' \
    "$CONFIG_JSON")
[ "$EGRESS_FILTER" = "null" ] && EGRESS_FILTER="false"

WORKSPACE_IMAGE="${WORKSPACE_IMAGE:-agents-workspace:latest}"
CONTAINER_NAME="workspace-${HOST_NAME}"

echo "=== Workspace setup for '$HOST_NAME' ==="
echo "  User:         $AGENT_USER"
echo "  Image:        $WORKSPACE_IMAGE"
echo "  Container:    $CONTAINER_NAME"
echo "  project_paths:"
echo "$PROJECT_PATHS" | while IFS= read -r p; do [ -n "$p" ] && echo "    - $p"; done
[ -n "$FORWARD_PORTS" ] && echo "  forward_ports: $FORWARD_PORTS" || echo "  forward_ports: (none)"
echo "  docker_access: $DOCKER_ACCESS"
echo "  egress_filter: $EGRESS_FILTER"
echo ""

# ── 1. Ensure AGENT_USER exists on host ────────────────────────────────────────
log_info "[1/7] Ensuring $AGENT_USER exists..."
if ! id "$AGENT_USER" &>/dev/null; then
    useradd -m -s /bin/bash "$AGENT_USER"
    log_info "  Created $AGENT_USER"
else
    log_info "  Already exists"
fi
AGENT_UID=$(id -u "$AGENT_USER")
AGENT_GID=$(id -g "$AGENT_USER")
AGENT_HOME=$(eval echo "~$AGENT_USER")

# ── 2. Validate project_paths and grant access via ACL ────────────────────────
log_info "[2/7] Validating project_paths..."
while IFS= read -r path; do
    [ -z "$path" ] && continue
    if [ ! -d "$path" ]; then
        log_error "  project_path does not exist: $path"
        log_error "  Create it on the host before running this script."
        exit 1
    fi
    if ! su -s /bin/bash "$AGENT_USER" -c "test -r '$path' && test -w '$path'" 2>/dev/null; then
        log_info "  Granting $AGENT_USER rw access to $path via ACL..."
        if command -v setfacl &>/dev/null; then
            # Grant traverse (x) on each parent dir so rootless Docker can
            # resolve the bind-mount source path without being blocked mid-tree.
            _parent="$path"
            while [ "$_parent" != "/" ]; do
                _parent="$(dirname "$_parent")"
                if ! su -s /bin/bash "$AGENT_USER" -c "test -x '$_parent'" 2>/dev/null; then
                    setfacl -m "u:$AGENT_USER:x" "$_parent"
                    log_info "    traverse: $_parent"
                fi
            done
            # Grant rw on the project dir itself; default ACL covers new files.
            setfacl -R  -m "u:$AGENT_USER:rwX" "$path"
            setfacl -Rd -m "u:$AGENT_USER:rwX" "$path"
            log_info "  ACL granted (new files will inherit access)"
        else
            log_warn "  setfacl not available — install acl package: apt install acl"
            log_warn "  Falling back: adding $AGENT_USER to $(stat -c %G "$path") group..."
            DIR_GROUP=$(stat -c %G "$path")
            usermod -aG "$DIR_GROUP" "$AGENT_USER"
            chmod -R g+rw "$path"
            chmod g+x "$(dirname "$path")"
            log_warn "  Group write set. SSH into $AGENT_USER may need a re-login to pick up group."
        fi
    else
        log_info "  $path — OK"
    fi
done <<< "$PROJECT_PATHS"

# ── 3. Install rootless Docker for AGENT_USER ──────────────────────────────────
log_info "[3/7] Installing/starting rootless Docker..."
bash "$SCRIPT_DIR/install_rootless_docker.sh"

DOCKER_SOCKET_PATH="/run/user/$AGENT_UID/docker.sock"
if [ ! -S "$DOCKER_SOCKET_PATH" ]; then
    log_error "Rootless Docker socket not found at $DOCKER_SOCKET_PATH"
    exit 1
fi

_docker() { su - "$AGENT_USER" -c "DOCKER_HOST=unix://$DOCKER_SOCKET_PATH PATH=\$HOME/bin:\$PATH docker $*"; }

# ── 4. Build workspace image (if not present) ──────────────────────────────────
log_info "[4/7] Ensuring workspace image is available..."
if ! _docker image inspect "$WORKSPACE_IMAGE" &>/dev/null; then
    log_info "  Image $WORKSPACE_IMAGE not found; building from agents/workspace/Dockerfile"
    WORKSPACE_CTX="$PROJECT_ROOT/agents/workspace"
    if [ ! -f "$WORKSPACE_CTX/Dockerfile" ]; then
        log_error "  agents/workspace/Dockerfile not found at $WORKSPACE_CTX"
        exit 1
    fi
    # Copy build context to a location dev-bot can read
    BUILD_TMP="/tmp/agents-workspace-build-$$"
    cp -r "$WORKSPACE_CTX" "$BUILD_TMP"
    chown -R "$AGENT_USER:$AGENT_USER" "$BUILD_TMP"
    _docker build \
        --build-arg "DEV_BOT_UID=$AGENT_UID" \
        --build-arg "DEV_BOT_GID=$AGENT_GID" \
        -t "$WORKSPACE_IMAGE" \
        "$BUILD_TMP"
    rm -rf "$BUILD_TMP"
    log_info "  Built $WORKSPACE_IMAGE"
else
    log_info "  Image already present"
fi

# ── 5. Start Docker socket proxy (docker_access only) ─────────────────────────
if [ "$DOCKER_ACCESS" = "true" ]; then
    log_info "[5/8] Starting Docker socket proxy..."

    PROXY_SOCKET_PATH="/run/user/$AGENT_UID/docker-proxy.sock"

    # Install proxy binary to a fixed path so it persists across su sessions.
    install -m 0755 "$SCRIPT_DIR/docker_proxy.py" /usr/local/bin/openclaw-docker-proxy

    # Stop any existing proxy on this socket before (re)starting.
    pkill -u "$AGENT_USER" -f 'openclaw-docker-proxy' 2>/dev/null || true
    sleep 0.5
    rm -f "$PROXY_SOCKET_PATH"

    # Build the launch command with properly shell-quoted paths.
    PROXY_CMD="python3 /usr/local/bin/openclaw-docker-proxy"
    PROXY_CMD="$PROXY_CMD $(printf '%q' "$PROXY_SOCKET_PATH")"
    PROXY_CMD="$PROXY_CMD $(printf '%q' "$DOCKER_SOCKET_PATH")"
    while IFS= read -r _p; do
        [ -z "$_p" ] && continue
        PROXY_CMD="$PROXY_CMD $(printf '%q' "$_p")"
    done <<< "$PROJECT_PATHS"

    su - "$AGENT_USER" -c \
        "nohup $PROXY_CMD </dev/null >/dev/null 2>&1 &"

    # Wait up to 10 s for the proxy socket to appear.
    for _ in $(seq 1 20); do
        [ -S "$PROXY_SOCKET_PATH" ] && break
        sleep 0.5
    done
    if [ ! -S "$PROXY_SOCKET_PATH" ]; then
        log_error "Docker proxy failed to start. Check $(dirname "$PROXY_SOCKET_PATH")/docker-proxy.log"
        exit 1
    fi
    log_info "  Proxy socket : $PROXY_SOCKET_PATH"
    log_info "  Allowed paths: $(echo "$PROJECT_PATHS" | tr '\n' ' ')"
else
    log_info "[5/8] Skipping Docker proxy (docker_access is false)"
fi

# ── 6. (Re)create the workspace container ──────────────────────────────────────
log_info "[6/8] Running workspace container..."

# Stop/remove any existing container with the same name so changes to
# project_paths / forward_ports / docker_access take effect on re-run.
if _docker inspect --type=container "$CONTAINER_NAME" &>/dev/null; then
    log_info "  Existing container found — recreating"
    _docker rm -f "$CONTAINER_NAME" >/dev/null
fi

# Build docker run arguments
RUN_ARGS=(
    run -d
    --name "$CONTAINER_NAME"
    --restart=unless-stopped
    --cap-drop=ALL
    --security-opt no-new-privileges:true
    --user "$AGENT_UID:$AGENT_GID"
)

# Bind-mount each project_path at ~/workspace/<basename>.
while IFS= read -r path; do
    [ -z "$path" ] && continue
    RUN_ARGS+=(-v "$path:/home/dev-bot/workspace/$(basename "$path"):rw")
done <<< "$PROJECT_PATHS"

# Publish forward_ports to host localhost
for port in $FORWARD_PORTS; do
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        log_error "Invalid port in forward_ports: '$port'"
        exit 1
    fi
    RUN_ARGS+=(-p "127.0.0.1:$port:$port")
done

# Docker-in-Docker: bind-mount the filtering proxy socket (never the real socket).
# The proxy enforces project_paths allowlist and blocks --privileged / network=host.
if [ "$DOCKER_ACCESS" = "true" ]; then
    PROXY_SOCKET_PATH="/run/user/$AGENT_UID/docker-proxy.sock"
    RUN_ARGS+=(-v "$PROXY_SOCKET_PATH:/var/run/docker.sock")
    RUN_ARGS+=(-e "DOCKER_HOST=unix:///var/run/docker.sock")
    log_info "  docker_access: bind-mounting filtered proxy socket (not the real daemon socket)"
fi

RUN_ARGS+=("$WORKSPACE_IMAGE" sleep infinity)

# Pass the arguments through su -> docker. Quote each arg safely for the shell.
_quoted_args=$(printf ' %q' "${RUN_ARGS[@]}")
su - "$AGENT_USER" -c "DOCKER_HOST=unix://$DOCKER_SOCKET_PATH PATH=\$HOME/bin:\$PATH docker$_quoted_args" >/dev/null
log_info "  Container '$CONTAINER_NAME' running"

# ── 6. Install session-entry ForceCommand script ───────────────────────────────
log_info "[7/8] Installing openclaw-session-entry..."
install -m 0755 "$SCRIPT_DIR/session_entry.sh" /usr/local/bin/openclaw-session-entry
log_info "  /usr/local/bin/openclaw-session-entry installed"

# ── 7. Configure sshd Match block (PermitOpen only — no ChrootDirectory) ───────
log_info "[8/8] Configuring sshd Match block..."
if [ -n "$FORWARD_PORTS" ]; then
    PERMIT_OPEN_LINE=""
    for port in $FORWARD_PORTS; do
        PERMIT_OPEN_LINE="${PERMIT_OPEN_LINE} localhost:${port}"
    done
    PERMIT_OPEN_LINE="${PERMIT_OPEN_LINE# }"
    TCP_FORWARDING_LINE="AllowTcpForwarding local"
    PERMIT_OPEN_CONFIG="    PermitOpen ${PERMIT_OPEN_LINE}"
else
    TCP_FORWARDING_LINE="AllowTcpForwarding no"
    PERMIT_OPEN_CONFIG=""
fi

SSHD_CONFIG_BLOCK="# BEGIN Dev-Agent Workspace Configuration
Match User $AGENT_USER
    X11Forwarding no
    ${TCP_FORWARDING_LINE}
    PermitTunnel no
    ClientAliveInterval 300
    ClientAliveCountMax 3
    MaxSessions 3
${PERMIT_OPEN_CONFIG}
# END Dev-Agent Workspace Configuration"

# Replace existing block (workspace or legacy chroot) so re-runs pick up changes.
for marker in "Dev-Agent Workspace Configuration" "Dev-Agent Chroot Configuration"; do
    if grep -q "# BEGIN $marker" /etc/ssh/sshd_config 2>/dev/null; then
        sed -i "/# BEGIN $marker/,/# END $marker/d" /etc/ssh/sshd_config
    fi
done
printf '\n%s\n' "$SSHD_CONFIG_BLOCK" >> /etc/ssh/sshd_config
log_info "  sshd_config updated (reload required)"

# ── 8. Optional: apply UID-keyed egress filter ─────────────────────────────────
if [ "$EGRESS_FILTER" = "true" ]; then
    echo ""
    log_info "Applying egress filter..."
    bash "$SCRIPT_DIR/egress_filter.sh" "$HOST_NAME"
fi

echo ""
log_info "=== Workspace ready for '$HOST_NAME' ==="
echo "  Container: $CONTAINER_NAME"
echo "  Socket:    $DOCKER_SOCKET_PATH"
echo ""
echo "Next steps:"
echo "  1. make key-add HOST=$HOST_NAME   (install ForceCommand authorized_keys)"
echo "  2. systemctl reload sshd          (apply sshd Match block)"
echo "  3. make test HOST=$HOST_NAME      (verify)"
