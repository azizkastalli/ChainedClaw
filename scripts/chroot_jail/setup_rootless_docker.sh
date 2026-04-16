#!/bin/bash
#
# Set up rootless Docker for the chroot user.
# Runs a rootless dockerd as AGENT_USER on the host (outside the chroot),
# then bind-mounts the socket into the chroot so the agent can use docker CLI.
#
# Rootless Docker provides:
#   - User namespace isolation (container root ≠ host root)
#   - No access to host Docker daemon
#   - --privileged, --pid=host, --network=host are all rejected
#
# Prerequisites on the remote host:
#   - uidmap package installed
#   - Kernel user namespaces enabled (kernel.unprivileged_userns_clone=1 on older kernels)
#   - /etc/subuid and /etc/subgid entries for AGENT_USER
#
# Usage: setup_rootless_docker.sh <host-name> [--uninstall]
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
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    log_error "This script must be run as root (use sudo)"
    exit 1
fi

# Load configuration
if [ ! -f "$ENV_FILE" ]; then
    log_error ".env file not found at $ENV_FILE"
    exit 1
fi
source "$ENV_FILE"

if [ -z "${1:-}" ]; then
    echo "Usage: $0 <host-name> [--uninstall]"
    exit 1
fi
HOST_NAME="$1"
UNINSTALL="${2:-}"

if ! id "$AGENT_USER" &>/dev/null; then
    log_error "User $AGENT_USER does not exist. Run jail_set.sh first."
    exit 1
fi

AGENT_UID=$(id -u "$AGENT_USER")
AGENT_HOME=$(eval echo "~$AGENT_USER")
DOCKER_SOCKET_PATH="/run/user/$AGENT_UID/docker.sock"

# Chroot mode creates the user without a real home directory (the home lives inside
# the jail at $CHROOT_BASE/home/$AGENT_USER). Rootless Docker runs outside the chroot
# as the real system user, so it needs a real home directory on the host filesystem.
if [ ! -d "$AGENT_HOME" ]; then
    log_info "Creating home directory $AGENT_HOME for $AGENT_USER (required for rootless Docker)..."
    mkdir -p "$AGENT_HOME"
    chown "$AGENT_USER:$AGENT_USER" "$AGENT_HOME"
    chmod 750 "$AGENT_HOME"
fi

# ── Uninstall mode ──────────────────────────────────────────────────────────
if [ "$UNINSTALL" = "--uninstall" ]; then
    echo "=== Removing rootless Docker for $AGENT_USER ==="

    # Stop rootless Docker
    if [ -S "$DOCKER_SOCKET_PATH" ]; then
        su - "$AGENT_USER" -c "dockerd-rootless-stop.sh" 2>/dev/null || true
        log_info "Rootless Docker daemon stopped"
    fi

    # Remove subuid/subgid entries
    if grep -q "^$AGENT_USER:" /etc/subuid 2>/dev/null; then
        sed -i "/^${AGENT_USER}:/d" /etc/subuid
        log_info "Removed /etc/subuid entry for $AGENT_USER"
    fi
    if grep -q "^$AGENT_USER:" /etc/subgid 2>/dev/null; then
        sed -i "/^${AGENT_USER}:/d" /etc/subgid
        log_info "Removed /etc/subgid entry for $AGENT_USER"
    fi

    # Remove the socket mount from chroot (if exists)
    CHROOT_BASE="${CHROOT_BASE:-/chroot/agent-dev}"
    if mountpoint -q "$CHROOT_BASE/run/user/$AGENT_UID" 2>/dev/null; then
        umount "$CHROOT_BASE/run/user/$AGENT_UID"
        log_info "Unmounted Docker socket from chroot"
    fi

    log_info "Rootless Docker removed for $AGENT_USER"
    exit 0
fi

# ── Install mode ────────────────────────────────────────────────────────────
echo "=== Setting up rootless Docker for $AGENT_USER ==="

# 1. Install prerequisites
log_info "[1/5] Checking prerequisites..."

if ! dpkg -l | grep -q uidmap 2>/dev/null; then
    log_info "Installing uidmap..."
    apt-get update -qq && apt-get install -y -qq uidmap >/dev/null 2>&1
fi

# Check kernel user namespace support
if [ -f /proc/sys/kernel/unprivileged_userns_clone ]; then
    UNS_CLONE=$(cat /proc/sys/kernel/unprivileged_userns_clone)
    if [ "$UNS_CLONE" != "1" ]; then
        log_error "Kernel user namespaces disabled. Enable with:"
        log_error "  sysctl -w kernel.unprivileged_userns_clone=1"
        exit 1
    fi
fi

# 2. Configure subuid/subgid
log_info "[2/5] Configuring subuid/subgid..."
if ! grep -q "^$AGENT_USER:" /etc/subuid 2>/dev/null; then
    # Allocate a range of 65536 UIDs starting from 100000
    echo "${AGENT_USER}:100000:65536" >> /etc/subuid
    log_info "Added /etc/subuid entry for $AGENT_USER"
else
    log_info "subuid entry already exists for $AGENT_USER"
fi

if ! grep -q "^$AGENT_USER:" /etc/subgid 2>/dev/null; then
    echo "${AGENT_USER}:100000:65536" >> /etc/subgid
    log_info "Added /etc/subgid entry for $AGENT_USER"
else
    log_info "subgid entry already exists for $AGENT_USER"
fi

# 3. Install rootless Docker (if not already installed)
log_info "[3/5] Installing rootless Docker..."
if ! su - "$AGENT_USER" -c "which docker" &>/dev/null; then
    # Install dockerd-rootless-extras if docker is already installed system-wide
    if command -v docker &>/dev/null; then
        # Docker CE is installed — just add rootless extras
        if ! dpkg -l | grep -q docker-ce-rootless-extras 2>/dev/null; then
            apt-get install -y -qq docker-ce-rootless-extras >/dev/null 2>&1 || true
        fi
    fi

    # If docker CLI still not available for the user, install via static binary
    if ! su - "$AGENT_USER" -c "which docker" &>/dev/null; then
        log_info "Installing Docker via static binary for $AGENT_USER..."
        su - "$AGENT_USER" -c '
            mkdir -p ~/bin
            curl -fsSL https://download.docker.com/linux/static/stable/x86_64/docker-27.5.1.tgz | \
                tar xz --strip-components=1 -C ~/bin docker/docker
            chmod +x ~/bin/docker
            echo "export PATH=$HOME/bin:$PATH" >> ~/.bashrc
        ' || {
            log_error "Failed to install Docker static binary"
            log_error "Install docker-ce-rootless-extras manually, then re-run this script"
            exit 1
        }
    fi
else
    log_info "Docker CLI already available for $AGENT_USER"
fi

# 4. Start rootless Docker daemon
log_info "[4/5] Starting rootless Docker daemon..."
if [ ! -S "$DOCKER_SOCKET_PATH" ]; then
    su - "$AGENT_USER" -c 'nohup dockerd-rootless.sh >/tmp/rootless-dockerd.log 2>&1 &'
    # Wait for socket to appear (up to 15 seconds)
    for i in $(seq 1 15); do
        if [ -S "$DOCKER_SOCKET_PATH" ]; then
            break
        fi
        sleep 1
    done

    if [ ! -S "$DOCKER_SOCKET_PATH" ]; then
        log_error "Rootless Docker daemon failed to start. Check /tmp/rootless-dockerd.log"
        exit 1
    fi
    log_info "Rootless Docker daemon started (socket: $DOCKER_SOCKET_PATH)"
else
    log_info "Rootless Docker daemon already running (socket: $DOCKER_SOCKET_PATH)"
fi

# 5. Bind-mount the Docker socket into the chroot
log_info "[5/5] Mounting Docker socket into chroot..."
CHROOT_BASE="${CHROOT_BASE:-/chroot/agent-dev}"
CHROOT_DOCKER_DIR="$CHROOT_BASE/run/user/$AGENT_UID"
CHROOT_DOCKER_SOCKET="$CHROOT_DOCKER_DIR/docker.sock"

mkdir -p "$CHROOT_DOCKER_DIR"

# Bind-mount the directory containing the socket
if ! mountpoint -q "$CHROOT_DOCKER_DIR" 2>/dev/null; then
    mount --bind "/run/user/$AGENT_UID" "$CHROOT_DOCKER_DIR"
    log_info "Mounted /run/user/$AGENT_UID → $CHROOT_DOCKER_DIR"
else
    log_info "Docker socket directory already mounted in chroot"
fi

# Add DOCKER_HOST to chroot environment
if ! grep -q "DOCKER_HOST" "$CHROOT_BASE/etc/environment" 2>/dev/null; then
    echo "DOCKER_HOST=unix:///run/user/$AGENT_UID/docker.sock" >> "$CHROOT_BASE/etc/environment"
    log_info "Added DOCKER_HOST to chroot /etc/environment"
fi

echo ""
log_info "=== Rootless Docker setup complete ==="
log_info "  Socket:   $DOCKER_SOCKET_PATH"
log_info "  User:     $AGENT_USER (UID $AGENT_UID)"
log_info "  Isolation: user namespace (cannot run --privileged, --pid=host, etc.)"
echo ""
log_info "The agent can now use 'docker build/run/ps' inside the chroot."
echo ""
log_info "To uninstall: $0 $HOST_NAME --uninstall"