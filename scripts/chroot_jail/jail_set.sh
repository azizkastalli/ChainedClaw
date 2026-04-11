#!/bin/bash
#
# Set up chroot jail for OpenClaw agent
# Creates isolated environment with project bind mounts
#
set -uo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Error handler - cleanup partial state on failure
cleanup_on_error() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        log_error "Script failed with exit code $exit_code"
        log_error "Attempting cleanup of partial state..."
        
        # Try to unmount anything that was mounted
        if [ -n "${CHROOT_BASE:-}" ] && [ -d "$CHROOT_BASE" ]; then
            for dir in proc sys dev/pts; do
                mountpoint -q "$CHROOT_BASE/$dir" 2>/dev/null && \
                     umount -l "$CHROOT_BASE/$dir" 2>/dev/null
            done
            for dir in usr/lib64 usr/lib bin lib64 lib; do
                mountpoint -q "$CHROOT_BASE/$dir" 2>/dev/null && \
                     umount -l "$CHROOT_BASE/$dir" 2>/dev/null
            done
        fi
        log_error "Cleanup attempted. Check $CHROOT_BASE for residual mounts."
    fi
}

trap cleanup_on_error EXIT

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
    log_error ".env file not found at $ENV_FILE"
    exit 1
fi
source "$ENV_FILE"

# CRITICAL: Validate CHROOT_BASE is set and is an absolute path
# This prevents accidental symlink creation in wrong locations
if [ -z "${CHROOT_BASE:-}" ]; then
    log_error "CHROOT_BASE is not set in .env file"
    exit 1
fi

if [[ ! "$CHROOT_BASE" =~ ^/ ]]; then
    log_error "CHROOT_BASE must be an absolute path (starting with /), got: $CHROOT_BASE"
    exit 1
fi

if [[ "$CHROOT_BASE" == "/" || "$CHROOT_BASE" == "/usr" || "$CHROOT_BASE" == "/bin" ]]; then
    log_error "CHROOT_BASE cannot be a critical system directory: $CHROOT_BASE"
    exit 1
fi

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

if [ -z "$PROJECT_PATHS" ]; then
    echo "ERROR: No project_paths found for host '$HOST_NAME' in $CONFIG_JSON"
    exit 1
fi

echo "=== Setting up Chroot with Bind Mounts ==="
echo "  User:    $AGENT_USER"
echo "  Chroot:  $CHROOT_BASE"
echo "  Host:    $HOST_NAME"
echo "  Projects:"
echo "$PROJECT_PATHS" | while read -r path; do
    [ -n "$path" ] && echo "    - $path"
done

# Helper function to safely mount - checks if already mounted first
do_mount() {
    local source="$1"
    local target="$2"
    local ro="$3"  # "ro" for read-only

    mkdir -p "$target"

    # Check if already mounted using mountpoint AND mount | grep
    # This is more reliable than just mountpoint -q alone
    if mountpoint -q "$target" 2>/dev/null || mount | grep -q "on $target "; then
        echo "  Already mounted: $target"
        return 0
    fi

    mount --bind "$source" "$target"

    if [ "$ro" = "ro" ]; then
        mount -o remount,ro "$target"
        echo "  Mounted: $source -> $target (ro)"
    else
        echo "  Mounted: $source -> $target (rw)"
    fi
}

# 1. Create chroot directory structure
echo "[1/6] Creating chroot directory structure..."

# SAFETY CHECK: Detect leftover /usr bind mount from previous runs
# This is critical to prevent symlink creation in host's /usr/bin
if mountpoint -q "$CHROOT_BASE/usr" 2>/dev/null; then
    log_error "============================================"
    log_error "SAFETY: Leftover bind mount detected!"
    log_error "============================================"
    log_error "  $CHROOT_BASE/usr is still bind-mounted"
    log_error ""
    log_error "This would cause symlinks to be created in the HOST's /usr/bin!"
    log_error ""
    log_error "To fix, run:"
    log_error "   umount $CHROOT_BASE/usr"
    log_error "   bash $0 $HOST_NAME"
    log_error "============================================"
    exit 1
fi

if mountpoint -q "$CHROOT_BASE/bin" 2>/dev/null; then
    echo "  Chroot already active, skipping directory creation"
else
     mkdir -p "$CHROOT_BASE"/{bin,lib,lib64,usr/bin,usr/lib,usr/lib64,dev,proc,sys}
     mkdir -p "$CHROOT_BASE/home/$AGENT_USER"
fi

# 2. Set up bind mounts for system directories (read-only)
echo "[2/6] Setting up bind mounts for system directories..."
# Mount bin, lib, lib64 directly (these are needed for basic shell operation)
for dir in bin lib lib64; do
    if [ -d "/$dir" ]; then
        do_mount "/$dir" "$CHROOT_BASE/$dir" "ro"
    fi
done

# Mount /usr/lib and /usr/lib64 (needed for shared libraries)
for dir in usr/lib usr/lib64; do
    if [ -d "/$dir" ]; then
        do_mount "/$dir" "$CHROOT_BASE/$dir" "ro"
    fi
done

# 2b. Create custom /usr/bin WITHOUT SSH binaries (prevent jumping to other hosts)
# We create symlinks to host binaries, explicitly excluding SSH and network tools
echo "[2b/6] Creating restricted /usr/bin (SSH removed)..."

# SAFETY CHECK 1: Verify CHROOT_BASE/usr/bin is inside the chroot
# This prevents accidental symlink creation in host system directories
CHROOT_USR_BIN="$CHROOT_BASE/usr/bin"
if [[ ! "$CHROOT_USR_BIN" =~ ^"$CHROOT_BASE" ]]; then
    log_error "SAFETY: Target directory $CHROOT_USR_BIN is not inside CHROOT_BASE"
    log_error "This indicates a configuration error. Aborting to prevent host damage."
    exit 1
fi

# SAFETY CHECK 2: Verify /srv/chroot/openclaw-bot/usr is NOT a bind mount to a critical system directory
# This prevents symlinks from being created in the host's /usr/bin
if mountpoint -q "$CHROOT_BASE/usr" 2>/dev/null; then
    mount_source=$(findmnt -n -o SOURCE "$CHROOT_BASE/usr" 2>/dev/null)
    # mount_target is intentionally unused - we just need to verify the mount exists
    log_error "============================================"
    log_error "SAFETY: CRITICAL BIND MOUNT DETECTED!"
    log_error "============================================"
    log_error "  $CHROOT_BASE/usr is bind-mounted to: $mount_source"
    log_error ""
    log_error "This would cause symlinks to be created in the HOST's /usr/bin!"
    log_error "This is a dangerous misconfiguration."
    log_error ""
    log_error "To fix, run:"
    log_error "   umount $CHROOT_BASE/usr"
    log_error "   bash $0 $HOST_NAME"
    log_error "============================================"
    exit 1
fi

# SAFETY CHECK 3: Verify the parent directory is not a bind mount to a critical system directory
if mountpoint -q "$CHROOT_BASE/usr/bin" 2>/dev/null; then
    log_error "============================================"
    log_error "SAFETY: CRITICAL BIND MOUNT DETECTED!"
    log_error "============================================"
    log_error "  $CHROOT_BASE/usr/bin is bind-mounted"
    log_error ""
    log_error "This would cause symlinks to be created in the HOST's /usr/bin!"
    log_error "To fix, run:"
    log_error "   umount $CHROOT_BASE/usr/bin"
    log_error "   bash $0 $HOST_NAME"
    log_error "============================================"
    exit 1
fi

 mkdir -p "$CHROOT_USR_BIN"

# List of binaries to EXCLUDE from chroot (security risk)
EXCLUDE_BINARIES="ssh scp sftp ssh-keygen ssh-keyscan ssh-agent ssh-add nc netcat ncat telnet rsh rlogin"

# Create symlinks for all binaries in /usr/bin, excluding the dangerous ones
for binary in /usr/bin/*; do
    [ -f "$binary" ] || continue
    binary_name=$(basename "$binary")
    
    # Skip excluded binaries
    skip=false
    for exclude in $EXCLUDE_BINARIES; do
        if [ "$binary_name" = "$exclude" ]; then
            skip=true
            log_info "  Excluding: $binary_name"
            break
        fi
    done
    
    if [ "$skip" = false ]; then
        # SAFETY: Always use full path for target to prevent relative symlink issues
         ln -sf "$binary" "$CHROOT_USR_BIN/$binary_name" 2>/dev/null || true
    fi
done

# Create /usr/local/bin for any custom scripts (writable)
 mkdir -p "$CHROOT_BASE/usr/local/bin"

log_info "  SSH and network tools removed from chroot"

# 3. Create minimal /etc files (don't copy from host to avoid leaking user info)
echo "[3/6] Creating minimal /etc files..."
 mkdir -p "$CHROOT_BASE/etc"

# Create minimal passwd with only required users
 tee "$CHROOT_BASE/etc/passwd" > /dev/null << 'PASSEOF'
root:x:0:0:root:/root:/bin/bash
nobody:x:65534:65534:nobody:/nonexistent:/usr/sbin/nologin
PASSEOF

# Create minimal group
 tee "$CHROOT_BASE/etc/group" > /dev/null << 'GROUPEOF'
root:x:0:
nogroup:x:65534:
GROUPEOF

# Copy network config (required for DNS resolution)
 cp /etc/resolv.conf "$CHROOT_BASE/etc/" 2>/dev/null || true
 cp /etc/hosts "$CHROOT_BASE/etc/" 2>/dev/null || true

 tee "$CHROOT_BASE/etc/nsswitch.conf" > /dev/null << 'EOF'
passwd:     files
group:      files
shadow:     files
hosts:      files dns
EOF

# 4. Bind mount project directory directly to user home (READ-WRITE)
# 4. Bind mount project directories to user home subdirectories (READ-WRITE)
echo "[4/6] Binding project directories to home (read-write)..."
while IFS= read -r project_path; do
    [ -z "$project_path" ] && continue
    
    if [ ! -d "$project_path" ]; then
        echo "  WARNING: Project path does not exist: $project_path"
        continue
    fi
    
    # Get the project name (last directory component)
    project_name=$(basename "$project_path")
    target_dir="$CHROOT_BASE/home/$AGENT_USER/$project_name"
    
    do_mount "$project_path" "$target_dir" "rw"
done <<< "$PROJECT_PATHS"

# 5. Create required /dev entries and mount virtual filesystems
echo "[5/6] Creating device nodes and virtual filesystems..."
 mkdir -p "$CHROOT_BASE/dev"
 mknod "$CHROOT_BASE/dev/null" c 1 3 2>/dev/null || true
 mknod "$CHROOT_BASE/dev/zero" c 1 5 2>/dev/null || true
 chmod 666 "$CHROOT_BASE/dev/null" "$CHROOT_BASE/dev/zero" 2>/dev/null || true

do_mount "/dev/pts" "$CHROOT_BASE/dev/pts" "rw"

# Mount proc/sys as dedicated filesystems (not bind mounts) to avoid
# read-only propagation that breaks Docker
 mkdir -p "$CHROOT_BASE/proc" "$CHROOT_BASE/sys"
if ! mountpoint -q "$CHROOT_BASE/proc" 2>/dev/null; then
     mount -t proc proc "$CHROOT_BASE/proc" -o ro
    echo "  Mounted: proc -> $CHROOT_BASE/proc (ro)"
else
    echo "  Already mounted: $CHROOT_BASE/proc"
fi
if ! mountpoint -q "$CHROOT_BASE/sys" 2>/dev/null; then
     mount -t sysfs sysfs "$CHROOT_BASE/sys" -o ro
    echo "  Mounted: sysfs -> $CHROOT_BASE/sys (ro)"
else
    echo "  Already mounted: $CHROOT_BASE/sys"
fi

# 6. Set up user and SSH keys
echo "[6/6] Configuring user..."

# Create user FIRST (before any chown calls)
if id "$AGENT_USER" &>/dev/null; then
     usermod -d "/home/$AGENT_USER" -s /bin/bash "$AGENT_USER" 2>/dev/null || true
else
     useradd -d "/home/$AGENT_USER" -s /bin/bash "$AGENT_USER"
fi

log_info "User $AGENT_USER created/updated"

# ChrootDirectory must be owned by root
 chown root:root "$CHROOT_BASE" 2>/dev/null || true
 chown root:root "$CHROOT_BASE/home" 2>/dev/null || true

# Ensure user entry in chroot's passwd/group
if ! grep -q "^$AGENT_USER:" "$CHROOT_BASE/etc/passwd" 2>/dev/null; then
    grep "^$AGENT_USER:" /etc/passwd |  tee -a "$CHROOT_BASE/etc/passwd" > /dev/null
fi
if ! grep -q "^$AGENT_USER:" "$CHROOT_BASE/etc/group" 2>/dev/null; then
    grep "^$AGENT_USER:" /etc/group |  tee -a "$CHROOT_BASE/etc/group" > /dev/null
fi

# SSH key installation is now handled separately
log_warn ""
log_warn "=========================================="
log_warn "SSH key NOT installed automatically."
log_warn "To enable agent access, run:"
log_warn "  make key-add HOST=$HOST_NAME"
log_warn "=========================================="
log_warn ""

# 7. Configure sshd
echo "[Configuring sshd...]"

SSHD_CONFIG_BLOCK="
# BEGIN OpenClaw Bot Chroot Configuration
Match User $AGENT_USER
    ChrootDirectory $CHROOT_BASE
    X11Forwarding no
    AllowTcpForwarding no
    PermitTunnel no
# END OpenClaw Bot Chroot Configuration
"

if ! grep -q "# BEGIN OpenClaw Bot Chroot Configuration" /etc/ssh/sshd_config 2>/dev/null; then
    echo "$SSHD_CONFIG_BLOCK" |  tee -a /etc/ssh/sshd_config > /dev/null
    echo "  Added ChrootDirectory config."
else
    echo "  ChrootDirectory already configured."
fi

echo ""
echo "=== Setup Complete ==="
echo "Chroot: $CHROOT_BASE"
echo "Project files accessible at:"
echo "$PROJECT_PATHS" | while IFS= read -r path; do
    [ -n "$path" ] && echo "  - /home/$AGENT_USER/$(basename "$path")"
done
echo ""
echo "Next steps:"
echo "  1.  systemctl reload sshd"
echo "  2. docker exec -it openclaw ssh $HOST_NAME ls"
