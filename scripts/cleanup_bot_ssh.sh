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

echo "=== Cleaning up Chroot setup ==="

# 1. Kill user processes
echo "[1/5] Killing user processes..."
sudo pkill -u "$AGENT_USER" 2>/dev/null || echo "  No active processes."

# 2. Unmount bind mounts (order matters - reverse of mounting)
echo "[2/5] Unmounting bind mounts..."

# Unmount virtual filesystems first
for mount_point in "/proc" "/sys" "/dev/pts" "/home/$AGENT_USER"; do
    if mountpoint -q "$CHROOT_BASE$mount_point" 2>/dev/null; then
        sudo umount "$CHROOT_BASE$mount_point" && echo "  Unmounted $mount_point" || \
        sudo umount -l "$CHROOT_BASE$mount_point" && echo "  Lazy unmounted $mount_point" || true
    fi
done

# Unmount system directories (deepest first)
for dir in "usr/lib64" "usr/lib" "usr/bin" "usr" "bin" "lib64" "lib"; do
    if mountpoint -q "$CHROOT_BASE/$dir" 2>/dev/null; then
        sudo umount "$CHROOT_BASE/$dir" && echo "  Unmounted /$dir" || \
        sudo umount -l "$CHROOT_BASE/$dir" && echo "  Lazy unmounted /$dir" || true
    fi
done

# 3. Remove user
echo "[3/5] Removing user..."
if id "$AGENT_USER" &>/dev/null; then
    sudo userdel "$AGENT_USER"
    echo "  User removed."
else
    echo "  User does not exist."
fi

# 4. Clean up chroot directory
echo "[4/5] Cleaning up chroot directory..."
if [ -d "$CHROOT_BASE" ]; then
    if ! mount | grep -q "$CHROOT_BASE"; then
        sudo rm -rf "$CHROOT_BASE"
        echo "  Chroot directory removed."
    else
        echo "  WARNING: Some mounts still active. Skipping removal for safety."
        echo "  Run 'mount | grep $CHROOT_BASE' to see remaining mounts."
    fi
fi

# 5. Remove sshd config
echo "[5/5] Removing sshd config..."
if grep -q "# BEGIN OpenClaw Bot Chroot Configuration" /etc/ssh/sshd_config 2>/dev/null; then
    sudo sed -i '/# BEGIN OpenClaw Bot Chroot Configuration/,/# END OpenClaw Bot Chroot Configuration/d' /etc/ssh/sshd_config
    echo "  Removed ChrootDirectory config."
elif grep -q "ChrootDirectory.*$AGENT_USER" /etc/ssh/sshd_config 2>/dev/null; then
    sudo sed -i '/# OpenClaw Bot Chroot Configuration/,+5d' /etc/ssh/sshd_config
    echo "  Removed legacy ChrootDirectory config."
fi

# Clean up real home directory
if [ -d "/home/$AGENT_USER" ]; then
    sudo rm -rf "/home/$AGENT_USER"
    echo "  Removed /home/$AGENT_USER (real filesystem)."
fi

echo ""
echo "=== Cleanup Complete ==="
echo "Run: sudo systemctl reload sshd"
echo "Your project at $PROJECT_PATH is untouched."
