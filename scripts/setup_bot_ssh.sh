#!/bin/bash
# Don't use set -e here — mount errors from stale lazy unmounts are expected
set -uo pipefail

# Load configuration from .env
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../.env"
if [ ! -f "$ENV_FILE" ]; then
    echo "ERROR: .env file not found at $ENV_FILE"
    exit 1
fi
source "$ENV_FILE"

echo "=== Setting up Chroot with Bind Mounts ==="
echo "  User:    $AGENT_USER"
echo "  Chroot:  $CHROOT_BASE"
echo "  Project: $PROJECT_PATH"

# Helper function to safely mount - checks if already mounted first
do_mount() {
    local source="$1"
    local target="$2"
    local ro="$3"  # "ro" for read-only

    sudo mkdir -p "$target"

    if mountpoint -q "$target" 2>/dev/null; then
        echo "  Already mounted: $target"
        return 0
    fi

    sudo mount --bind "$source" "$target"

    if [ "$ro" = "ro" ]; then
        sudo mount -o remount,ro "$target"
        echo "  Mounted: $source -> $target (ro)"
    else
        echo "  Mounted: $source -> $target (rw)"
    fi
}

# 1. Create chroot directory structure
echo "[1/6] Creating chroot directory structure..."
if mountpoint -q "$CHROOT_BASE/bin" 2>/dev/null; then
    echo "  Chroot already active, skipping directory creation"
else
    sudo mkdir -p "$CHROOT_BASE"/{bin,lib,lib64,usr/bin,usr/lib,usr/lib64,dev,proc,sys}
    sudo mkdir -p "$CHROOT_BASE/home/$AGENT_USER"
fi

# 2. Set up bind mounts for system directories (read-only)
echo "[2/6] Setting up bind mounts for system directories..."
for dir in bin lib lib64 usr usr/bin usr/lib usr/lib64; do
    if [ -d "/$dir" ]; then
        do_mount "/$dir" "$CHROOT_BASE/$dir" "ro"
    fi
done

# 3. Copy essential /etc files + nsswitch.conf
echo "[3/6] Copying essential /etc files..."
sudo mkdir -p "$CHROOT_BASE/etc"
sudo cp /etc/passwd "$CHROOT_BASE/etc/"
sudo cp /etc/group "$CHROOT_BASE/etc/"
sudo cp /etc/resolv.conf "$CHROOT_BASE/etc/" 2>/dev/null || true
sudo cp /etc/hosts "$CHROOT_BASE/etc/" 2>/dev/null || true

sudo tee "$CHROOT_BASE/etc/nsswitch.conf" > /dev/null << 'EOF'
passwd:     files
group:      files
shadow:     files
hosts:      files dns
EOF

# 4. Bind mount project directory directly to user home (READ-WRITE)
echo "[4/6] Binding project directory to home (read-write)..."
do_mount "$PROJECT_PATH" "$CHROOT_BASE/home/$AGENT_USER" "rw"

# 5. Create required /dev entries and mount virtual filesystems
echo "[5/6] Creating device nodes and virtual filesystems..."
sudo mkdir -p "$CHROOT_BASE/dev"
sudo mknod "$CHROOT_BASE/dev/null" c 1 3 2>/dev/null || true
sudo mknod "$CHROOT_BASE/dev/zero" c 1 5 2>/dev/null || true
sudo chmod 666 "$CHROOT_BASE/dev/null" "$CHROOT_BASE/dev/zero" 2>/dev/null || true

do_mount "/dev/pts" "$CHROOT_BASE/dev/pts" "rw"

# Mount proc/sys as dedicated filesystems (not bind mounts) to avoid
# read-only propagation that breaks Docker
sudo mkdir -p "$CHROOT_BASE/proc" "$CHROOT_BASE/sys"
if ! mountpoint -q "$CHROOT_BASE/proc" 2>/dev/null; then
    sudo mount -t proc proc "$CHROOT_BASE/proc" -o ro
    echo "  Mounted: proc -> $CHROOT_BASE/proc (ro)"
else
    echo "  Already mounted: $CHROOT_BASE/proc"
fi
if ! mountpoint -q "$CHROOT_BASE/sys" 2>/dev/null; then
    sudo mount -t sysfs sysfs "$CHROOT_BASE/sys" -o ro
    echo "  Mounted: sysfs -> $CHROOT_BASE/sys (ro)"
else
    echo "  Already mounted: $CHROOT_BASE/sys"
fi

# 6. Set up user and SSH keys
echo "[6/6] Configuring user..."

# Create user FIRST (before any chown calls)
if id "$AGENT_USER" &>/dev/null; then
    sudo usermod -d "/home/$AGENT_USER" -s /bin/bash "$AGENT_USER" 2>/dev/null || true
else
    sudo useradd -d "/home/$AGENT_USER" -s /bin/bash "$AGENT_USER"
fi

# Get the key from container
AGENT_PUB_KEY=$(docker exec openclaw cat /root/.ssh/id_openclaw.pub 2>/dev/null)
if [ -z "$AGENT_PUB_KEY" ]; then
    echo "ERROR: Could not get SSH key from container!"
    echo "Make sure the container is running and has SSH keys."
    exit 1
fi

# Install authorized_keys in chroot
sudo mkdir -p "$CHROOT_BASE/home/$AGENT_USER/.ssh"
echo "$AGENT_PUB_KEY" | sudo tee "$CHROOT_BASE/home/$AGENT_USER/.ssh/authorized_keys" > /dev/null

# ChrootDirectory must be owned by root
sudo chown root:root "$CHROOT_BASE" 2>/dev/null || true
sudo chown root:root "$CHROOT_BASE/home" 2>/dev/null || true

# .ssh must be owned by the user
sudo chown -R "$AGENT_USER:$AGENT_USER" "$CHROOT_BASE/home/$AGENT_USER/.ssh"
sudo chmod 700 "$CHROOT_BASE/home/$AGENT_USER/.ssh"
sudo chmod 600 "$CHROOT_BASE/home/$AGENT_USER/.ssh/authorized_keys"

# Ensure user entry in chroot's passwd/group
if ! grep -q "^$AGENT_USER:" "$CHROOT_BASE/etc/passwd" 2>/dev/null; then
    grep "^$AGENT_USER:" /etc/passwd | sudo tee -a "$CHROOT_BASE/etc/passwd" > /dev/null
fi
if ! grep -q "^$AGENT_USER:" "$CHROOT_BASE/etc/group" 2>/dev/null; then
    grep "^$AGENT_USER:" /etc/group | sudo tee -a "$CHROOT_BASE/etc/group" > /dev/null
fi

# CRITICAL: sshd resolves AuthorizedKeysFile on the REAL filesystem.
# Create authorized_keys at the real home path too.
sudo mkdir -p "/home/$AGENT_USER/.ssh"
sudo cp "$CHROOT_BASE/home/$AGENT_USER/.ssh/authorized_keys" "/home/$AGENT_USER/.ssh/authorized_keys"
sudo chown -R "$AGENT_USER:$AGENT_USER" "/home/$AGENT_USER"
sudo chmod 700 "/home/$AGENT_USER/.ssh"
sudo chmod 600 "/home/$AGENT_USER/.ssh/authorized_keys"

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
    echo "$SSHD_CONFIG_BLOCK" | sudo tee -a /etc/ssh/sshd_config > /dev/null
    echo "  Added ChrootDirectory config."
else
    echo "  ChrootDirectory already configured."
fi

echo ""
echo "=== Setup Complete ==="
echo "Chroot: $CHROOT_BASE"
echo "Project files accessible at: /home/$AGENT_USER/ (via SSH)"
echo ""
echo "Next steps:"
echo "  1. sudo systemctl reload sshd"
echo "  2. docker exec -it openclaw ssh my-host ls"
