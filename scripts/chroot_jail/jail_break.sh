#!/bin/bash
# Don't use set -e here - we want to continue even if some cleanup steps fail
set -uo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    log_error "This script must be run as root (use sudo)"
    log_error "Usage: sudo bash $0 <host-name>"
    exit 1
fi

# Load configuration from .env
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../../.env"
CONFIG_JSON="$SCRIPT_DIR/../../config.json"

if [ ! -f "$ENV_FILE" ]; then
    echo "ERROR: .env file not found at $ENV_FILE"
    exit 1
fi
source "$ENV_FILE"

# Get host name from command line argument
if [ -z "${1:-}" ]; then
    echo "ERROR: Host name required as argument"
    echo "Usage: $0 <host-name>"
    exit 1
fi
HOST_NAME="$1"

# Function to get project_paths from config.json for a given host
get_project_paths() {
    local host="$1"
    # Use /usr/bin/python3 explicitly to ensure it works with 
    /usr/bin/python3 -c "
import json
import sys

try:
    with open('$CONFIG_JSON', 'r') as f:
        config = json.load(f)
    
    if 'ssh_hosts' in config:
        for h in config['ssh_hosts']:
            if h.get('name') == '$host':
                paths = h.get('project_paths', [])
                if paths:
                    for p in paths:
                        print(p)
                    sys.exit(0)
    print('')
except Exception as e:
    print('', file=sys.stderr)
    sys.exit(1)
"
}

# Get project paths for this host
PROJECT_PATHS=$(get_project_paths "$HOST_NAME")

# If no project_paths found, try to clean up anyway if chroot exists
if [ -z "$PROJECT_PATHS" ]; then
    echo "WARN: No project_paths found for host '$HOST_NAME' in $CONFIG_JSON"
    if [ -d "$CHROOT_BASE" ]; then
        echo "INFO: Chroot directory exists at $CHROOT_BASE, attempting cleanup..."
    else
        echo "INFO: No chroot directory found at $CHROOT_BASE, nothing to clean up."
        exit 0
    fi
fi

echo "=== Cleaning up Chroot setup for host: $HOST_NAME ==="

# 1. Kill user processes
echo "[1/5] Killing user processes..."
 pkill -u "$AGENT_USER" 2>/dev/null || echo "  No active processes."

# 2. Unmount bind mounts (order matters - reverse of mounting)
echo "[2/5] Unmounting bind mounts..."

# Function to unmount with fallback to lazy unmount
do_unmount() {
    local target="$1"
    if mountpoint -q "$target" 2>/dev/null || mount | grep -q "on $target "; then
        # Try regular unmount first
        if umount "$target" 2>/dev/null; then
            echo "  Unmounted: $target"
        # Fall back to lazy unmount if regular fails
        elif umount -l "$target" 2>/dev/null; then
            echo "  Lazy unmounted: $target"
        else
            log_warn "Failed to unmount: $target"
        fi
    fi
}

# Get all mounts under chroot and unmount them in reverse order (deepest first)
# This is more reliable than hardcoding paths
echo "  Finding all mounts under $CHROOT_BASE..."
CHROOT_MOUNTS=$(mount | grep "$CHROOT_BASE" | awk '{print $3}' | sort -r)

if [ -n "$CHROOT_MOUNTS" ]; then
    echo "  Unmounting in reverse order..."
    for mount_path in $CHROOT_MOUNTS; do
        do_unmount "$mount_path"
    done
fi

# Also try specific paths as fallback
# Unmount project subdirectories first (individual project paths)
if [ -n "$PROJECT_PATHS" ]; then
    echo "  Checking project directories..."
    while IFS= read -r project_path; do
        [ -z "$project_path" ] && continue
        project_name=$(basename "$project_path")
        mount_point="$CHROOT_BASE/home/$AGENT_USER/$project_name"
        do_unmount "$mount_point"
    done <<< "$PROJECT_PATHS"
fi

# Check for home directory mount (from older setups)
do_unmount "$CHROOT_BASE/home/$AGENT_USER"

# Verify all mounts are gone
echo "  Checking for remaining mounts..."
REMAINING=$(mount | grep -c "$CHROOT_BASE" || true)
if [ "$REMAINING" -gt 0 ]; then
    log_warn "  $REMAINING mounts still active:"
    mount | grep "$CHROOT_BASE" | while read -r line; do
        log_warn "    $line"
    done
    # Force lazy unmount on remaining
    log_warn "  Force unmounting remaining mounts..."
    mount | grep "$CHROOT_BASE" | awk '{print $3}' | while read -r mp; do
        umount -l "$mp" 2>/dev/null && log_info "  Lazy unmounted: $mp" || true
    done
else
    log_info "  All mounts successfully unmounted"
fi

# 3. Remove user
echo "[3/5] Removing user..."
if id "$AGENT_USER" &>/dev/null; then
     userdel "$AGENT_USER"
    echo "  User removed."
else
    echo "  User does not exist."
fi

# 4. Clean up chroot directory
echo "[4/5] Cleaning up chroot directory..."
if [ -d "$CHROOT_BASE" ]; then
    if ! mount | grep -q "$CHROOT_BASE"; then
         rm -rf "$CHROOT_BASE"
        echo "  Chroot directory removed."
    else
        echo "  WARNING: Some mounts still active. Skipping removal for safety."
        echo "  Run 'mount | grep $CHROOT_BASE' to see remaining mounts."
    fi
fi

# 5. Remove sshd config
echo "[5/5] Removing sshd config..."
if grep -q "# BEGIN OpenClaw Bot Chroot Configuration" /etc/ssh/sshd_config 2>/dev/null; then
     sed -i '/# BEGIN OpenClaw Bot Chroot Configuration/,/# END OpenClaw Bot Chroot Configuration/d' /etc/ssh/sshd_config
    echo "  Removed ChrootDirectory config."
elif grep -q "ChrootDirectory.*$AGENT_USER" /etc/ssh/sshd_config 2>/dev/null; then
     sed -i '/# OpenClaw Bot Chroot Configuration/,+5d' /etc/ssh/sshd_config
    echo "  Removed legacy ChrootDirectory config."
fi

# Clean up real home directory
if [ -d "/home/${AGENT_USER:?}" ]; then
    rm -rf "/home/${AGENT_USER:?}"
    echo "  Removed /home/$AGENT_USER (real filesystem)."
fi

echo ""
echo "=== Cleanup Complete ==="
echo "Run:  systemctl reload sshd"
echo "Your projects are untouched:"
echo "$PROJECT_PATHS" | while IFS= read -r path; do
    [ -n "$path" ] && echo "  - $path"
done
