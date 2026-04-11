#!/bin/bash
#
# Install SSH public key to chroot jail authorized_keys
# Used after jail_set.sh to enable agent access
#
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Load configuration from .env
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../../.env"

if [ ! -f "$ENV_FILE" ]; then
    log_error ".env file not found at $ENV_FILE"
    exit 1
fi
source "$ENV_FILE"

# Validate required variables
if [ -z "${CHROOT_BASE:-}" ]; then
    log_error "CHROOT_BASE is not set in .env"
    exit 1
fi
if [ -z "${AGENT_USER:-}" ]; then
    log_error "AGENT_USER is not set in .env"
    exit 1
fi

echo "=== Installing SSH Key to Chroot ==="
echo "  User:    $AGENT_USER"
echo "  Chroot:  $CHROOT_BASE"
echo ""

# Get the SSH public key
# Priority: 1) Project .ssh directory, 2) Container (user 1000)
SSH_KEY_FILE="$SCRIPT_DIR/../../.ssh/id_openclaw.pub"

if [ -f "$SSH_KEY_FILE" ]; then
    KEY=$(cat "$SSH_KEY_FILE")
    log_info "Using SSH key from: $SSH_KEY_FILE"
else
    # Fallback: get from container (user 1000, NOT root!)
    KEY=$(docker exec openclaw cat /home/openclaw/.ssh/id_openclaw.pub 2>/dev/null)
    if [ -z "$KEY" ]; then
        log_error "SSH public key not found"
        log_error ""
        log_error "Tried locations:"
        log_error "  1. $SSH_KEY_FILE"
        log_error "  2. Container: /home/openclaw/.ssh/id_openclaw.pub"
        log_error ""
        log_error "Run: bash scripts/ssh_key/init_keys.sh"
        exit 1
    fi
    log_info "Using SSH key from container"
fi

log_info "Installing authorized_keys..."

# Install in chroot
 mkdir -p "$CHROOT_BASE/home/$AGENT_USER/.ssh"
echo "$KEY" |  tee "$CHROOT_BASE/home/$AGENT_USER/.ssh/authorized_keys" > /dev/null
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
log_info "=== SSH Key Installed ==="
echo ""
echo "Run ' systemctl reload sshd' to apply changes."
