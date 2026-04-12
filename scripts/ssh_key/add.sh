#!/bin/bash
#
# Install SSH public key for the openclaw agent.
#
# Isolation modes (set per-host in config.json):
#   chroot        — installs key into chroot + real home (default)
#   restricted_key — installs key into real home with SSH restrictions
#                    (no port forwarding, no agent forwarding, no X11)
#
# Usage: add.sh [host-name]
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

if [ -z "${CHROOT_BASE:-}" ]; then
    log_error "CHROOT_BASE is not set in .env"
    exit 1
fi
if [ -z "${AGENT_USER:-}" ]; then
    log_error "AGENT_USER is not set in .env"
    exit 1
fi

# Read isolation mode from config.json (default: chroot)
HOST_NAME="${1:-}"
ISOLATION="chroot"
if [ -n "$HOST_NAME" ] && [ -f "$CONFIG_JSON" ] && command -v jq &>/dev/null; then
    _iso=$(jq -r --arg name "$HOST_NAME" \
        '.ssh_hosts[] | select(.name == $name) | .isolation // "chroot"' \
        "$CONFIG_JSON" 2>/dev/null)
    [ -n "$_iso" ] && [ "$_iso" != "null" ] && ISOLATION="$_iso"
fi

# Read the public key
SSH_KEY_FILE="$SCRIPT_DIR/../../.ssh/id_openclaw.pub"
if [ -f "$SSH_KEY_FILE" ]; then
    KEY=$(cat "$SSH_KEY_FILE")
    log_info "Using SSH key from: $SSH_KEY_FILE"
else
    KEY=$(docker exec openclaw cat /home/openclaw/.ssh/id_openclaw.pub 2>/dev/null)
    if [ -z "$KEY" ]; then
        log_error "SSH public key not found"
        log_error "Tried: $SSH_KEY_FILE and container /home/openclaw/.ssh/id_openclaw.pub"
        log_error "Run: make keys"
        exit 1
    fi
    log_info "Using SSH key from container"
fi

# ── chroot mode ────────────────────────────────────────────────────────────────
if [ "$ISOLATION" = "chroot" ]; then
    echo "=== Installing SSH Key to Chroot ==="
    echo "  User:    $AGENT_USER"
    echo "  Chroot:  $CHROOT_BASE"
    echo ""

    log_info "Installing authorized_keys..."

    # Install in chroot
    mkdir -p "$CHROOT_BASE/home/$AGENT_USER/.ssh"
    echo "$KEY" | tee "$CHROOT_BASE/home/$AGENT_USER/.ssh/authorized_keys" > /dev/null
    chmod 700 "$CHROOT_BASE/home/$AGENT_USER/.ssh"
    chmod 600 "$CHROOT_BASE/home/$AGENT_USER/.ssh/authorized_keys"
    chown -R "$AGENT_USER:$AGENT_USER" "$CHROOT_BASE/home/$AGENT_USER/.ssh"
    log_info "Installed: $CHROOT_BASE/home/$AGENT_USER/.ssh/authorized_keys"

    # Sync to real home (sshd resolves AuthorizedKeysFile on real filesystem)
    mkdir -p "/home/$AGENT_USER/.ssh"
    cp "$CHROOT_BASE/home/$AGENT_USER/.ssh/authorized_keys" "/home/$AGENT_USER/.ssh/authorized_keys"
    chown -R "$AGENT_USER:$AGENT_USER" "/home/$AGENT_USER"
    chmod 700 "/home/$AGENT_USER/.ssh"
    chmod 600 "/home/$AGENT_USER/.ssh/authorized_keys"
    log_info "Installed: /home/$AGENT_USER/.ssh/authorized_keys"

    echo ""
    log_info "=== SSH Key Installed (chroot mode) ==="
    echo ""
    echo "Run 'systemctl reload sshd' to apply changes."

# ── restricted_key mode ────────────────────────────────────────────────────────
elif [ "$ISOLATION" = "restricted_key" ]; then
    echo "=== Installing Restricted SSH Key ==="
    echo "  User:      $AGENT_USER"
    echo "  Mode:      restricted_key (no chroot)"
    echo "  Restrictions: no-port-forwarding, no-agent-forwarding, no-X11-forwarding"
    echo ""

    # Prefix the key with SSH restrictions.
    # restrict  — disables forwarding, PTY, user-rc, X11
    # pty       — re-enables PTY so the agent can run interactive commands
    RESTRICTED_KEY="restrict,pty $KEY"

    mkdir -p "/home/$AGENT_USER/.ssh"
    echo "$RESTRICTED_KEY" | tee "/home/$AGENT_USER/.ssh/authorized_keys" > /dev/null
    chown -R "$AGENT_USER:$AGENT_USER" "/home/$AGENT_USER/.ssh"
    chmod 700 "/home/$AGENT_USER/.ssh"
    chmod 600 "/home/$AGENT_USER/.ssh/authorized_keys"
    log_info "Installed: /home/$AGENT_USER/.ssh/authorized_keys (with restrictions)"

    echo ""
    log_info "=== SSH Key Installed (restricted_key mode) ==="
    log_info "No sshd reload required."

else
    log_error "Unknown isolation mode: '$ISOLATION'"
    log_error "Valid values: chroot, restricted_key"
    exit 1
fi
