#!/bin/bash
#
# Tear down workspace on a remote SSH host
# Runs workspace_down.sh on the remote using the previously copied scripts
# in /tmp/agent-dev-scripts, then removes that directory.
#
# hostname and port are read from config.json using the host name.
#
# Usage: teardown.sh <host-name> <ssh-key> [remote-user]
#
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# ------------------------------------------------------------------------------
# Arguments
# ------------------------------------------------------------------------------

if [ $# -lt 2 ]; then
    echo "Usage: $0 <host-name> <ssh-key> [remote-user]"
    echo ""
    echo "  host-name   Host name as defined in config.json"
    echo "  ssh-key     Path to the SSH private key for connecting to the remote"
    echo "  remote-user SSH user on the remote (default: current user)"
    echo ""
    echo "  hostname and port are read from config.json automatically."
    echo ""
    echo "Example:"
    echo "  $0 my-host ~/.ssh/id_rsa ubuntu"
    exit 1
fi

HOST_NAME="$1"
SSH_KEY="$2"
REMOTE_USER="${3:-$(whoami)}"
PURGE="${4:-}"   # pass --purge to also remove AGENT_USER and rootless Docker
REMOTE_DIR="/tmp/agent-dev-scripts"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# ------------------------------------------------------------------------------
# Validate
# ------------------------------------------------------------------------------

if [ ! -f "$SSH_KEY" ]; then
    log_error "SSH key not found: $SSH_KEY"
    exit 1
fi

if ! command -v jq &>/dev/null; then
    log_error "jq is required but not installed. Install with: apt install jq"
    exit 1
fi

if [ ! -f "$PROJECT_ROOT/config.json" ]; then
    log_error "config.json not found at $PROJECT_ROOT/config.json"
    exit 1
fi

# Read hostname, port, and isolation mode from config.json
REMOTE_IP=$(jq -r --arg name "$HOST_NAME" \
    '.ssh_hosts[] | select(.name == $name) | .hostname' \
    "$PROJECT_ROOT/config.json")

REMOTE_PORT=$(jq -r --arg name "$HOST_NAME" \
    '.ssh_hosts[] | select(.name == $name) | .port // 22' \
    "$PROJECT_ROOT/config.json")

ISOLATION=$(jq -r --arg name "$HOST_NAME" \
    '.ssh_hosts[] | select(.name == $name) | .isolation // "container"' \
    "$PROJECT_ROOT/config.json")
[ -z "$ISOLATION" ] || [ "$ISOLATION" = "null" ] && ISOLATION="container"

if [ -z "$REMOTE_IP" ] || [ "$REMOTE_IP" = "null" ]; then
    log_error "Host '$HOST_NAME' not found in config.json"
    exit 1
fi

SSH_OPTS=(
    -i "$SSH_KEY"
    -p "$REMOTE_PORT"
    -o StrictHostKeyChecking=accept-new
    -o BatchMode=yes
    -o ConnectTimeout=15
    -o ServerAliveInterval=10
    -o ServerAliveCountMax=3
)
SSH_SUDO_OPTS=(
    -i "$SSH_KEY"
    -p "$REMOTE_PORT"
    -tt
    -o StrictHostKeyChecking=accept-new
    -o ConnectTimeout=15
    -o ServerAliveInterval=10
    -o ServerAliveCountMax=3
)

# Check SSH connectivity first, then verify the scripts directory exists
log_info "Verifying SSH connection to $REMOTE_USER@$REMOTE_IP..."
if ! ssh "${SSH_OPTS[@]}" "$REMOTE_USER@$REMOTE_IP" true; then
    log_error "Cannot connect to $REMOTE_USER@$REMOTE_IP"
    log_error "Check your SSH key, remote user, and that the host is reachable."
    exit 1
fi

if ! ssh "${SSH_OPTS[@]}" "$REMOTE_USER@$REMOTE_IP" "test -d $REMOTE_DIR"; then
    log_error "$REMOTE_DIR not found on $REMOTE_IP"
    log_error "Was remote-setup run for this host? Or was the directory removed manually?"
    log_error "If removed manually, SSH into the remote and run workspace_down.sh directly:"
    log_error "  bash scripts/workspace/workspace_down.sh $HOST_NAME"
    exit 1
fi

# ------------------------------------------------------------------------------
# Run
# ------------------------------------------------------------------------------

echo ""
echo "=== Remote Teardown ==="
log_info "  Host name : $HOST_NAME"
log_info "  Isolation : $ISOLATION"
log_info "  Remote    : $REMOTE_USER@$REMOTE_IP:$REMOTE_PORT"
log_info "  SSH key   : $SSH_KEY"
log_info "  Remote dir: $REMOTE_DIR"
echo ""

# 1. Run teardown
log_info "[1/3] Running teardown on remote..."
if ! ssh "${SSH_OPTS[@]}" "$REMOTE_USER@$REMOTE_IP" 'sudo -n true 2>/dev/null'; then
    log_warn "  '$REMOTE_USER' does not have passwordless sudo. Will prompt for password."
    log_warn "  If this fails, re-run with an admin user: REMOTE_USER=<admin-user>"
fi
ssh "${SSH_SUDO_OPTS[@]}" "$REMOTE_USER@$REMOTE_IP" "
    set -e
    cd $REMOTE_DIR
    sudo bash scripts/workspace/workspace_down.sh $HOST_NAME $PURGE
    sudo bash scripts/ssh_key/remove.sh $HOST_NAME
"

# 2. Reload sshd — required for container mode (removes Match User block from sshd_config)
if [ "$ISOLATION" = "container" ]; then
    log_info "[2/3] Reloading sshd on remote..."
    if ssh "${SSH_SUDO_OPTS[@]}" "$REMOTE_USER@$REMOTE_IP" \
        'export PATH=/usr/sbin:/sbin:/usr/bin:/bin:$PATH
         sudo systemctl reload sshd 2>/dev/null \
         || sudo systemctl reload ssh 2>/dev/null \
         || sudo service sshd reload 2>/dev/null \
         || sudo service ssh reload 2>/dev/null \
         || systemctl reload sshd 2>/dev/null \
         || systemctl reload ssh 2>/dev/null \
         || service sshd reload 2>/dev/null \
         || service ssh reload 2>/dev/null \
         || kill -HUP $(pgrep -f "sshd" | head -1) 2>/dev/null'; then
        log_info "  sshd reloaded successfully"
    else
        log_warn "  Could not reload sshd — the Match User block may still be in sshd_config."
        log_warn "  SSH into the remote and run: service ssh reload  (or: kill -HUP \$(pgrep -f sshd))"
    fi
else
    log_info "[2/3] Skipping sshd reload (not needed for restricted_key mode)"
fi

# 3. Remove scripts directory
log_info "[3/3] Removing $REMOTE_DIR from remote..."
ssh "${SSH_OPTS[@]}" "$REMOTE_USER@$REMOTE_IP" "rm -rf $REMOTE_DIR"
log_info "  Removed $REMOTE_DIR"

echo ""
log_info "=== Remote teardown complete ==="
log_info "  Workspace container for '$HOST_NAME' removed from $REMOTE_IP"
echo ""
