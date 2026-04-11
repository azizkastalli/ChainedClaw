#!/bin/bash
#
# Remove SSH key from chroot jail
# This removes the authorized_keys without tearing down the entire chroot
#

set -euo pipefail

# Load configuration from .env
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../../.env"

if [ ! -f "$ENV_FILE" ]; then
    echo "ERROR: .env file not found at $ENV_FILE"
    exit 1
fi
source "$ENV_FILE"

echo "=== Removing SSH key from chroot jail ==="
echo "  User:    $AGENT_USER"
echo "  Chroot:  $CHROOT_BASE"

# Check if chroot exists
if [ ! -d "$CHROOT_BASE" ]; then
    echo "WARNING: Chroot directory does not exist: $CHROOT_BASE"
    echo "Nothing to remove."
    exit 0
fi

# Remove authorized_keys from chroot
CHROOT_SSH_DIR="$CHROOT_BASE/home/$AGENT_USER/.ssh"
if [ -d "$CHROOT_SSH_DIR" ]; then
     rm -f "$CHROOT_SSH_DIR/authorized_keys"
    echo "  Removed: $CHROOT_SSH_DIR/authorized_keys"
else
    echo "  WARNING: Chroot .ssh directory does not exist"
fi

# Remove authorized_keys from real home (sshd resolves this for ChrootDirectory)
REAL_SSH_DIR="/home/$AGENT_USER/.ssh"
if [ -d "$REAL_SSH_DIR" ]; then
     rm -f "$REAL_SSH_DIR/authorized_keys"
    echo "  Removed: $REAL_SSH_DIR/authorized_keys"
else
    echo "  Note: Real home .ssh directory does not exist"
fi

echo ""
echo "=== SSH Key Removed ==="
echo "The authorized_keys have been removed from both:"
echo "  - $CHROOT_BASE/home/$AGENT_USER/.ssh/"
echo "  - /home/$AGENT_USER/.ssh/"
echo ""
echo "Run ' systemctl reload sshd' to apply changes."