#!/bin/bash
set -euo pipefail

# Load configuration from .env
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../.env"
if [ ! -f "$ENV_FILE" ]; then
    echo "ERROR: .env file not found at $ENV_FILE"
    exit 1
fi
source "$ENV_FILE"

# Get key from container
KEY=$(docker exec openclaw cat /root/.ssh/id_openclaw.pub 2>/dev/null)
if [ -z "$KEY" ]; then
    echo "ERROR: SSH public key not found on openclaw container"
    exit 1
fi

echo "Adding SSH key..."

# Install in chroot
sudo mkdir -p "$CHROOT_BASE/home/$AGENT_USER/.ssh"
echo "$KEY" | sudo tee "$CHROOT_BASE/home/$AGENT_USER/.ssh/authorized_keys" > /dev/null
sudo chmod 700 "$CHROOT_BASE/home/$AGENT_USER/.ssh"
sudo chmod 600 "$CHROOT_BASE/home/$AGENT_USER/.ssh/authorized_keys"
sudo chown -R "$AGENT_USER:$AGENT_USER" "$CHROOT_BASE/home/$AGENT_USER/.ssh"

# Sync to real home (sshd resolves AuthorizedKeysFile on real filesystem)
sudo mkdir -p "/home/$AGENT_USER/.ssh"
sudo cp "$CHROOT_BASE/home/$AGENT_USER/.ssh/authorized_keys" "/home/$AGENT_USER/.ssh/authorized_keys"
sudo chown -R "$AGENT_USER:$AGENT_USER" "/home/$AGENT_USER"
sudo chmod 700 "/home/$AGENT_USER/.ssh"
sudo chmod 600 "/home/$AGENT_USER/.ssh/authorized_keys"

echo "Done! Run: sudo systemctl reload sshd"
