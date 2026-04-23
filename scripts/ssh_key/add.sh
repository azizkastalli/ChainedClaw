#!/bin/bash
#
# Install SSH public key for the dev agent.
#
# Isolation modes (set per-host in config.json):
#   container      — installs key with ForceCommand=openclaw-session-entry,
#                    routes every SSH session into the workspace container
#   restricted_key — installs key in real home with SSH flag restrictions
#                    (no port forwarding, no agent forwarding, no X11)
#
# Usage: add.sh <host-name>
#
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../../.env"
CONFIG_JSON="$SCRIPT_DIR/../../config.json"

if [ ! -f "$ENV_FILE" ]; then
    log_error ".env file not found at $ENV_FILE"
    exit 1
fi
source "$ENV_FILE"

if [ -z "${AGENT_USER:-}" ]; then
    log_error "AGENT_USER is not set in .env"
    exit 1
fi

HOST_NAME="${1:-}"
ISOLATION="container"
if [ -n "$HOST_NAME" ] && [ -f "$CONFIG_JSON" ] && command -v jq &>/dev/null; then
    _iso=$(jq -r --arg name "$HOST_NAME" \
        '.ssh_hosts[] | select(.name == $name) | .isolation // "container"' \
        "$CONFIG_JSON" 2>/dev/null)
    [ -n "$_iso" ] && [ "$_iso" != "null" ] && ISOLATION="$_iso"
fi

# Read the public key
SSH_KEY_FILE="$SCRIPT_DIR/../../.ssh/id_agent.pub"
CONTAINER_NAME_AGENT="${AGENT_CONTAINER_NAME:-agent-dev}"
if [ -f "$SSH_KEY_FILE" ]; then
    KEY=$(cat "$SSH_KEY_FILE")
    log_info "Using SSH key from: $SSH_KEY_FILE"
else
    KEY=$(docker exec "$CONTAINER_NAME_AGENT" cat /home/openclaw/.ssh-keys/id_agent.pub 2>/dev/null \
          || docker exec "$CONTAINER_NAME_AGENT" cat /home/node/.ssh-keys/id_agent.pub 2>/dev/null \
          || docker exec "$CONTAINER_NAME_AGENT" cat /home/hermes/.ssh-keys/id_agent.pub 2>/dev/null \
          || docker exec "$CONTAINER_NAME_AGENT" cat /root/.ssh/id_agent.pub 2>/dev/null)
    if [ -z "$KEY" ]; then
        log_error "SSH public key not found"
        log_error "Run: make keys"
        exit 1
    fi
    log_info "Using SSH key from container"
fi

# Tag the key line with a stable comment so remove.sh can target it.
# Strip any existing trailing comment and append our marker.
KEY_MARKER="openclaw-agent-${HOST_NAME:-default}"
KEY_FIELDS=$(echo "$KEY" | awk '{print $1" "$2}')
TAGGED_KEY="$KEY_FIELDS $KEY_MARKER"

install_authorized_keys_line() {
    local line="$1"
    local ssh_dir="/home/$AGENT_USER/.ssh"
    local auth_keys="$ssh_dir/authorized_keys"

    mkdir -p "$ssh_dir"
    touch "$auth_keys"

    # Remove any existing line matching our marker (idempotent replace).
    if grep -q " $KEY_MARKER\$" "$auth_keys" 2>/dev/null; then
        sed -i "/ $KEY_MARKER\$/d" "$auth_keys"
    fi

    # Append the new line.
    echo "$line" >> "$auth_keys"

    chown -R "$AGENT_USER:$AGENT_USER" "$ssh_dir"
    chmod 700 "$ssh_dir"
    chmod 600 "$auth_keys"
    log_info "Installed: $auth_keys"
}

case "$ISOLATION" in
    container)
        if [ -z "$HOST_NAME" ]; then
            log_error "container mode requires HOST_NAME (for ForceCommand container target)"
            exit 1
        fi
        echo "=== Installing SSH key (container mode) ==="
        echo "  User:      $AGENT_USER"
        echo "  Mode:      container (ForceCommand → docker exec workspace-$HOST_NAME)"
        echo ""

        # restrict disables forwarding/PTY/X11; add pty back so interactive shells work.
        # command= forces the session into the named workspace container.
        FORCE_CMD="/usr/local/bin/openclaw-session-entry workspace-$HOST_NAME"
        LINE="command=\"$FORCE_CMD\",restrict,pty $TAGGED_KEY"

        if [ ! -x /usr/local/bin/openclaw-session-entry ]; then
            log_warn "/usr/local/bin/openclaw-session-entry missing —"
            log_warn "  make sure workspace_up.sh has run for this host."
        fi

        install_authorized_keys_line "$LINE"
        echo ""
        log_info "=== SSH Key Installed (container mode) ==="
        echo "Run 'systemctl reload sshd' to apply the Match block."
        ;;

    restricted_key)
        echo "=== Installing SSH key (restricted_key mode) ==="
        echo "  User:         $AGENT_USER"
        echo "  Restrictions: no-port-forwarding, no-agent-forwarding, no-X11-forwarding"
        echo ""

        LINE="restrict,pty $TAGGED_KEY"
        install_authorized_keys_line "$LINE"
        echo ""
        log_info "=== SSH Key Installed (restricted_key mode) ==="
        log_info "No sshd reload required."
        ;;

    *)
        log_error "Unknown isolation mode: '$ISOLATION'"
        log_error "Valid values: container, restricted_key"
        exit 1
        ;;
esac
