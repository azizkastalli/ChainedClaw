#!/bin/bash
#
# Remove the openclaw SSH key.
#
# Isolation modes (set per-host in config.json):
#   chroot        — removes from chroot + real home (default)
#   restricted_key — removes from real home only
#
# Usage: remove.sh [host-name]
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../../.env"
CONFIG_JSON="$SCRIPT_DIR/../../config.json"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

if [ ! -f "$ENV_FILE" ]; then
    echo "ERROR: .env file not found at $ENV_FILE"
    exit 1
fi
source "$ENV_FILE"

# Read isolation mode from config.json (default: chroot)
HOST_NAME="${1:-}"
ISOLATION="chroot"
if [ -n "$HOST_NAME" ] && [ -f "$CONFIG_JSON" ] && command -v jq &>/dev/null; then
    _iso=$(jq -r --arg name "$HOST_NAME" \
        '.ssh_hosts[] | select(.name == $name) | .isolation // "chroot"' \
        "$CONFIG_JSON" 2>/dev/null)
    [ -n "$_iso" ] && [ "$_iso" != "null" ] && ISOLATION="$_iso"
fi

echo "=== Removing SSH key ==="
echo "  User:  $AGENT_USER"
echo "  Mode:  $ISOLATION"

# ── chroot mode ────────────────────────────────────────────────────────────────
if [ "$ISOLATION" = "chroot" ]; then
    CHROOT_SSH_DIR="$CHROOT_BASE/home/$AGENT_USER/.ssh"
    if [ -d "$CHROOT_SSH_DIR" ]; then
        rm -f "$CHROOT_SSH_DIR/authorized_keys"
        log_info "Removed: $CHROOT_SSH_DIR/authorized_keys"
    else
        log_warn "Chroot .ssh directory not found: $CHROOT_SSH_DIR"
    fi
fi

# Both modes: remove from real home
REAL_SSH_DIR="/home/$AGENT_USER/.ssh"
if [ -d "$REAL_SSH_DIR" ]; then
    rm -f "$REAL_SSH_DIR/authorized_keys"
    log_info "Removed: $REAL_SSH_DIR/authorized_keys"
else
    log_warn "Real home .ssh directory not found: $REAL_SSH_DIR"
fi

echo ""
echo "=== SSH Key Removed ==="
if [ "$ISOLATION" = "chroot" ]; then
    echo "Run 'systemctl reload sshd' to apply changes."
fi
