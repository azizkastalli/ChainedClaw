#!/bin/bash
#
# Set up workspace on a remote SSH host
# Copies scripts, config, .env, and public key to the remote then runs
# workspace_up.sh and add.sh remotely.
#
# hostname and port are read from config.json using the host name.
#
# The /tmp/agent-dev-scripts directory is intentionally left on the remote
# so that teardown.sh can use it later without re-copying files.
#
# Usage: setup.sh <host-name> <ssh-key> [remote-user]
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

for f in "$PROJECT_ROOT/.env" "$PROJECT_ROOT/config.json" "$PROJECT_ROOT/.ssh/id_agent.pub"; do
    if [ ! -f "$f" ]; then
        log_error "Required file not found: $f"
        exit 1
    fi
done

if ! command -v jq &>/dev/null; then
    log_error "jq is required but not installed. Install with: apt install jq"
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
    log_error "Add it before running this script."
    exit 1
fi

# ssh uses -p (lowercase), scp uses -P (uppercase) for port
SSH_OPTS=(
    -i "$SSH_KEY"
    -p "$REMOTE_PORT"
    -o StrictHostKeyChecking=accept-new
    -o BatchMode=yes
    -o ConnectTimeout=15
    -o ServerAliveInterval=10
    -o ServerAliveCountMax=3
)
# SSH_SUDO_OPTS: same as SSH_OPTS but with TTY allocation so sudo can prompt for a password
SSH_SUDO_OPTS=(
    -i "$SSH_KEY"
    -p "$REMOTE_PORT"
    -tt
    -o StrictHostKeyChecking=accept-new
    -o ConnectTimeout=15
    -o ServerAliveInterval=10
    -o ServerAliveCountMax=3
)
SCP_OPTS=(
    -i "$SSH_KEY"
    -P "$REMOTE_PORT"
    -o StrictHostKeyChecking=accept-new
    -o BatchMode=yes
    -o ConnectTimeout=15
    -o ServerAliveInterval=10
    -o ServerAliveCountMax=3
)

# ------------------------------------------------------------------------------
# Run
# ------------------------------------------------------------------------------

echo ""
echo "=== Remote Setup ==="
log_info "  Host name : $HOST_NAME"
log_info "  Isolation : $ISOLATION"
log_info "  Remote    : $REMOTE_USER@$REMOTE_IP:$REMOTE_PORT"
log_info "  SSH key   : $SSH_KEY"
log_info "  Remote dir: $REMOTE_DIR"
echo ""

# 1. Create directory structure on remote (restricted permissions)
log_info "[1/4] Creating remote directory structure..."
ssh "${SSH_OPTS[@]}" "$REMOTE_USER@$REMOTE_IP" "mkdir -p $REMOTE_DIR/.ssh && chmod 700 $REMOTE_DIR"
log_info "  Created $REMOTE_DIR/.ssh on $REMOTE_IP (chmod 700)"

# 2. Copy required files (only what's needed — NOT the full .env which may contain secrets)
log_info "[2/4] Copying files to remote..."
scp -r "${SCP_OPTS[@]}" \
    "$PROJECT_ROOT/scripts/" \
    "$PROJECT_ROOT/config.json" \
    "$REMOTE_USER@$REMOTE_IP:$REMOTE_DIR/"
scp "${SCP_OPTS[@]}" \
    "$PROJECT_ROOT/.ssh/id_agent.pub" \
    "$REMOTE_USER@$REMOTE_IP:$REMOTE_DIR/.ssh/"

# Copy only the specific variables needed by the remote scripts (not the full .env)
# This avoids leaking DASHBOARD_PASSWORD and other unrelated secrets on remote hosts.
grep -E '^(AGENT_USER|AGENT_CONTAINER_NAME|WORKSPACE_IMAGE)=' "$PROJECT_ROOT/.env" > /tmp/openclaw-env-scoped 2>/dev/null || true
scp "${SCP_OPTS[@]}" /tmp/openclaw-env-scoped "$REMOTE_USER@$REMOTE_IP:$REMOTE_DIR/.env"
rm -f /tmp/openclaw-env-scoped

# Copy the workspace Dockerfile build context so workspace_up.sh can build it remotely.
scp -r "${SCP_OPTS[@]}" \
    "$PROJECT_ROOT/agents" \
    "$REMOTE_USER@$REMOTE_IP:$REMOTE_DIR/"
log_info "  Copied scripts, agents/workspace, scoped .env, config.json, id_agent.pub"

# Check that the remote user can sudo (gives a clear error before attempting privileged steps)
log_info "[3/4] Running setup and installing SSH key on remote..."
if ! ssh "${SSH_OPTS[@]}" "$REMOTE_USER@$REMOTE_IP" 'sudo -n true 2>/dev/null'; then
    log_warn "  '$REMOTE_USER' does not have passwordless sudo. Will prompt for password."
    log_warn "  If this fails, re-run with an admin user: REMOTE_USER=<admin-user>"
fi
ssh "${SSH_SUDO_OPTS[@]}" "$REMOTE_USER@$REMOTE_IP" "
    set -e
    cd $REMOTE_DIR
    sudo bash scripts/workspace/workspace_up.sh $HOST_NAME
    sudo bash scripts/ssh_key/add.sh $HOST_NAME
"

# 4. Reload sshd — required for container mode (adds Match User block to sshd_config)
if [ "$ISOLATION" = "container" ]; then
    log_info "[4/4] Reloading sshd on remote..."
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
        log_error "  Failed to reload sshd on remote."
        log_error "  SSH in manually and run: service ssh reload  (or: kill -HUP \$(pgrep -f sshd))"
        log_error "  The workspace sshd block will NOT be active until sshd reloads."
        exit 1
    fi
else
    log_info "[4/4] Skipping sshd reload (not needed for restricted_key mode)"
fi

echo ""
log_info "=== Remote setup complete ==="
log_info "  Test connection : make test HOST=$HOST_NAME"
log_info "  To uninstall   : make workspace-clean HOST=$HOST_NAME REMOTE_KEY=$SSH_KEY${3:+ REMOTE_USER=$REMOTE_USER}"
echo ""
