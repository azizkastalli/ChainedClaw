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
    if ! command -v jq &>/dev/null; then
        log_error "jq is required but not installed. Install with: apt install jq"
        exit 1
    fi
    # Use --arg to pass host name safely — no shell injection possible
    jq -r --arg name "$host" \
        '.ssh_hosts[] | select(.name == $name) | .project_paths[]' \
        "$CONFIG_JSON" 2>/dev/null
}

# Function to get forward_ports from config.json for a given host
# Returns space-separated list of port numbers, empty string if none configured
get_forward_ports() {
    local host="$1"
    jq -r --arg name "$host" \
        '.ssh_hosts[] | select(.name == $name) | .forward_ports // [] | .[] | tostring' \
        "$CONFIG_JSON" 2>/dev/null | tr '\n' ' ' | xargs
}

# Read isolation mode (default: chroot)
ISOLATION=$(jq -r --arg name "$HOST_NAME" \
    '.ssh_hosts[] | select(.name == $name) | .isolation // "chroot"' \
    "$CONFIG_JSON" 2>/dev/null)
[ -z "$ISOLATION" ] || [ "$ISOLATION" = "null" ] && ISOLATION="chroot"

# restricted_key mode: just create the user and exit — no chroot needed
if [ "$ISOLATION" = "restricted_key" ]; then
    echo "=== Isolation mode: restricted_key (no chroot) ==="
    echo "  User: $AGENT_USER"
    if id "$AGENT_USER" &>/dev/null; then
        log_info "User $AGENT_USER already exists"
    else
        useradd -m -s /bin/bash "$AGENT_USER"
        log_info "User $AGENT_USER created"
    fi
    echo ""
    log_info "User ready. Install the SSH key with restrictions:"
    log_info "  make key-add HOST=$HOST_NAME"
    exit 0
fi

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

# Try bind mount, then remount read-only if requested.
# Returns 0 on success, 1 on failure.
_try_bind_mount() {
    local source="$1" target="$2" ro="$3"
    if mountpoint -q "$target" 2>/dev/null || mount | grep -q "on $target "; then
        echo "  Already mounted: $target"
        return 0
    fi
    if mount --bind "$source" "$target" 2>/dev/null; then
        if [ "$ro" = "ro" ]; then
            mount -o remount,ro "$target" 2>/dev/null || true
            echo "  Mounted: $source -> $target (ro)"
        else
            echo "  Mounted: $source -> $target (rw)"
        fi
        return 0
    fi
    return 1
}

# Mount a system directory (bin, lib, etc.) — falls back to copying with a
# progress bar when bind mount is not permitted (unprivileged Docker).
do_mount() {
    local source="$1"
    local target="$2"
    local ro="$3"  # "ro" for read-only

    mkdir -p "$target"

    if _try_bind_mount "$source" "$target" "$ro"; then
        return 0
    fi

    # Bind mount failed — fall back to copying (system dirs only; acceptable cost).
    log_warn "  Bind mount not permitted for $target — copying instead (unprivileged container?)"
    local total copied=0 pct filled empty bar
    total=$(find "$source" -mindepth 1 -maxdepth 3 | wc -l)
    [ "$total" -eq 0 ] && total=1
    printf "  Copying %-30s [%-20s] %3d%%" "$(basename "$source")" "" 0
    while IFS= read -r -d '' f; do
        rel="${f#"$source"/}"
        dest="$target/$rel"
        if [ -d "$f" ]; then
            mkdir -p "$dest"
        else
            mkdir -p "$(dirname "$dest")"
            cp -a "$f" "$dest" 2>/dev/null || true
        fi
        copied=$(( copied + 1 ))
        pct=$(( copied * 100 / total ))
        filled=$(( pct / 5 ))
        empty=$(( 20 - filled ))
        bar="$(printf '%0.s#' $(seq 1 $filled 2>/dev/null))$(printf '%0.s.' $(seq 1 $empty 2>/dev/null))"
        printf "\r  Copying %-30s [%-20s] %3d%%" "$(basename "$source")" "$bar" "$pct"
    done < <(find "$source" -mindepth 1 -maxdepth 3 -print0)
    printf "\r  Copied  %-30s [####################] 100%%\n" "$(basename "$source")"
    if [ "$ro" = "ro" ]; then
        chmod -R a-w "$target" 2>/dev/null || true
    fi
}

# Mount a project directory — bind mount ONLY, no copy fallback.
# Copying project dirs (which may contain multi-GB model weights) would fill
# the disk. If bind mount fails the host needs CAP_SYS_ADMIN / --privileged.
do_mount_project() {
    local source="$1"
    local target="$2"

    mkdir -p "$target"

    if _try_bind_mount "$source" "$target" "rw"; then
        return 0
    fi

    log_error "============================================"
    log_error "BIND MOUNT REQUIRED for project directory"
    log_error "============================================"
    log_error "  Cannot bind-mount: $source -> $target"
    log_error ""
    log_error "  Project directories are never copied — they may contain"
    log_error "  large model weights that would fill the disk."
    log_error ""
    log_error "  This host does not have CAP_SYS_ADMIN (typical of"
    log_error "  unprivileged Docker containers such as RunPod)."
    log_error ""
    log_error "  To fix on RunPod: re-create the pod with 'Privileged mode'"
    log_error "  enabled in the pod settings, then re-run:"
    log_error "    make remote-setup HOST=$HOST_NAME REMOTE_KEY=<key> REMOTE_USER=<user>"
    log_error "============================================"
    exit 1
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
    
    do_mount_project "$project_path" "$target_dir"
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

# Read forward_ports for this host and build PermitOpen / AllowTcpForwarding lines.
# If forward_ports is empty: AllowTcpForwarding no  (no tunnelling at all)
# If forward_ports is set:   AllowTcpForwarding local + PermitOpen localhost:PORT ...
#   PermitOpen is the definitive enforcement — the remote sshd will refuse forwarding
#   requests to any destination not in this list, regardless of client flags.
FORWARD_PORTS=$(get_forward_ports "$HOST_NAME")

if [ -n "$FORWARD_PORTS" ]; then
    # Validate: each value must be a plain integer in 1-65535
    PERMIT_OPEN_LINE=""
    for port in $FORWARD_PORTS; do
        if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
            log_error "Invalid port in forward_ports for $HOST_NAME: '$port' (must be 1-65535)"
            exit 1
        fi
        PERMIT_OPEN_LINE="${PERMIT_OPEN_LINE} localhost:${port}"
    done
    PERMIT_OPEN_LINE="${PERMIT_OPEN_LINE# }"  # trim leading space

    TCP_FORWARDING_LINE="AllowTcpForwarding local"
    PERMIT_OPEN_CONFIG="    PermitOpen ${PERMIT_OPEN_LINE}"
    log_info "Port forwarding enabled for: $PERMIT_OPEN_LINE"
else
    TCP_FORWARDING_LINE="AllowTcpForwarding no"
    PERMIT_OPEN_CONFIG=""
    log_info "Port forwarding disabled (no forward_ports configured)"
fi

SSHD_CONFIG_BLOCK="# BEGIN OpenClaw Bot Chroot Configuration
Match User $AGENT_USER
    ChrootDirectory $CHROOT_BASE
    X11Forwarding no
    ${TCP_FORWARDING_LINE}
    PermitTunnel no
${PERMIT_OPEN_CONFIG}
# END OpenClaw Bot Chroot Configuration"

# Always replace the block so changes to forward_ports are picked up on re-run.
# Strategy: remove lines between the BEGIN/END markers (inclusive), then append fresh block.
if grep -q "# BEGIN OpenClaw Bot Chroot Configuration" /etc/ssh/sshd_config 2>/dev/null; then
    # Remove the existing block (BEGIN through END, inclusive)
     sed -i '/# BEGIN OpenClaw Bot Chroot Configuration/,/# END OpenClaw Bot Chroot Configuration/d' \
        /etc/ssh/sshd_config
    echo "  Replaced existing ChrootDirectory config."
else
    echo "  Adding ChrootDirectory config."
fi

# Remove any blank lines that sed may have left at the end, then append
printf '\n%s\n' "$SSHD_CONFIG_BLOCK" |  tee -a /etc/ssh/sshd_config > /dev/null

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
