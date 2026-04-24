#!/bin/bash
#
# Install and start rootless Docker for AGENT_USER on the remote host.
#
# Rootless Docker runs dockerd as the unprivileged AGENT_USER (not root).
# Its socket lives at /run/user/<uid>/docker.sock. Containers launched by
# this daemon run inside a user namespace — container root maps to a
# subordinate UID on the host, never to real root.
#
# Used by:
#   - workspace_up.sh: the workspace container itself runs under this daemon
#     so its egress packets appear as AGENT_USER UID (preserves UID-keyed
#     egress filter matches on AGENT_USER UID).
#   - docker_access: true hosts: the same socket is bind-mounted into the
#     workspace container so the agent can docker build/run on the host.
#
# Idempotent: safe to re-run.
#
# Usage:
#   install_rootless_docker.sh           # install & start
#   install_rootless_docker.sh --uninstall
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../../.env"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

if [ "$EUID" -ne 0 ]; then
    log_error "Must run as root (use sudo)"
    exit 1
fi

if [ ! -f "$ENV_FILE" ]; then
    log_error ".env not found at $ENV_FILE"
    exit 1
fi
source "$ENV_FILE"

UNINSTALL="${1:-}"

# AGENT_USER must exist on the host — workspace_up.sh creates it before calling this.
if ! id "$AGENT_USER" &>/dev/null; then
    log_error "User $AGENT_USER does not exist. Create it first (workspace_up.sh does this)."
    exit 1
fi

AGENT_UID=$(id -u "$AGENT_USER")
AGENT_HOME=$(eval echo "~$AGENT_USER")
DOCKER_SOCKET_PATH="/run/user/$AGENT_UID/docker.sock"

if [ ! -d "$AGENT_HOME" ]; then
    log_info "Creating $AGENT_HOME for $AGENT_USER..."
    mkdir -p "$AGENT_HOME"
    chown "$AGENT_USER:$AGENT_USER" "$AGENT_HOME"
    chmod 750 "$AGENT_HOME"
fi

# ── Uninstall ──────────────────────────────────────────────────────────────────
if [ "$UNINSTALL" = "--uninstall" ]; then
    echo "=== Removing rootless Docker for $AGENT_USER ==="
    if [ -S "$DOCKER_SOCKET_PATH" ]; then
        su - "$AGENT_USER" -c "dockerd-rootless-stop.sh" 2>/dev/null || true
        log_info "Rootless Docker daemon stopped"
    fi
    if grep -q "^$AGENT_USER:" /etc/subuid 2>/dev/null; then
        sed -i "/^${AGENT_USER}:/d" /etc/subuid
        log_info "Removed /etc/subuid entry"
    fi
    if grep -q "^$AGENT_USER:" /etc/subgid 2>/dev/null; then
        sed -i "/^${AGENT_USER}:/d" /etc/subgid
        log_info "Removed /etc/subgid entry"
    fi
    log_info "Rootless Docker removed"
    exit 0
fi

# ── Install ────────────────────────────────────────────────────────────────────
echo "=== Rootless Docker setup for $AGENT_USER (UID $AGENT_UID) ==="

log_info "[1/4] Checking prerequisites..."
if ! dpkg -l 2>/dev/null | grep -q uidmap; then
    apt-get update -qq
    apt-get install -y -qq uidmap >/dev/null 2>&1
fi

if [ -f /proc/sys/kernel/unprivileged_userns_clone ]; then
    UNS_CLONE=$(cat /proc/sys/kernel/unprivileged_userns_clone)
    if [ "$UNS_CLONE" != "1" ]; then
        log_error "Kernel user namespaces disabled. Enable with:"
        log_error "  sysctl -w kernel.unprivileged_userns_clone=1"
        exit 1
    fi
fi

log_info "[2/4] Configuring subuid/subgid..."
if ! grep -q "^$AGENT_USER:" /etc/subuid 2>/dev/null; then
    echo "${AGENT_USER}:100000:65536" >> /etc/subuid
    log_info "  Added /etc/subuid"
fi
if ! grep -q "^$AGENT_USER:" /etc/subgid 2>/dev/null; then
    echo "${AGENT_USER}:100000:65536" >> /etc/subgid
    log_info "  Added /etc/subgid"
fi

log_info "[3/4] Installing rootless Docker binaries..."
if ! su - "$AGENT_USER" -c "which docker" &>/dev/null; then
    if command -v docker &>/dev/null; then
        if ! dpkg -l 2>/dev/null | grep -q docker-ce-rootless-extras; then
            apt-get install -y -qq docker-ce-rootless-extras >/dev/null 2>&1 || true
        fi
    fi
    if ! su - "$AGENT_USER" -c "which docker" &>/dev/null; then
        log_info "  Installing Docker static binaries for $AGENT_USER..."
        su - "$AGENT_USER" -c '
            set -e
            mkdir -p ~/bin
            curl -fsSL https://download.docker.com/linux/static/stable/x86_64/docker-27.5.1.tgz \
                | tar xz --strip-components=1 -C ~/bin
            chmod +x ~/bin/*
            grep -q "export PATH=\$HOME/bin:\$PATH" ~/.bashrc 2>/dev/null \
                || echo "export PATH=\$HOME/bin:\$PATH" >> ~/.bashrc
        ' || { log_error "Static-binary install failed"; exit 1; }
    fi
else
    log_info "  Docker CLI already present for $AGENT_USER"
fi

log_info "[4/4] Starting rootless dockerd..."
if [ ! -S "$DOCKER_SOCKET_PATH" ]; then
    # /run/user/<uid> must exist before dockerd-rootless.sh runs — PAM creates
    # it on interactive login, but dev-bot may never have logged in interactively.
    RUNTIME_DIR="/run/user/$AGENT_UID"
    if [ ! -d "$RUNTIME_DIR" ]; then
        mkdir -p "$RUNTIME_DIR"
        chown "$AGENT_USER:$AGENT_USER" "$RUNTIME_DIR"
        chmod 700 "$RUNTIME_DIR"
        log_info "  Created $RUNTIME_DIR"
    fi

    # Enable linger so the daemon survives logout and host reboots (when combined
    # with a systemd user service; without linger, /run/user/<uid> disappears).
    loginctl enable-linger "$AGENT_USER" 2>/dev/null || true

    DOCKERD_LOG="$AGENT_HOME/dockerd.log"
    touch "$DOCKERD_LOG"
    chown "$AGENT_USER:$AGENT_USER" "$DOCKERD_LOG"

    su - "$AGENT_USER" -c "XDG_RUNTIME_DIR=$RUNTIME_DIR nohup dockerd-rootless.sh >>$DOCKERD_LOG 2>&1 &"
    for _ in $(seq 1 20); do
        [ -S "$DOCKER_SOCKET_PATH" ] && break
        sleep 1
    done
    if [ ! -S "$DOCKER_SOCKET_PATH" ]; then
        log_error "dockerd-rootless failed to start. See $DOCKERD_LOG"
        log_error "--- $DOCKERD_LOG ---"
        tail -30 "$DOCKERD_LOG" 2>/dev/null || true
        log_error "---------------------------------"
        exit 1
    fi
    log_info "  Started (socket: $DOCKER_SOCKET_PATH)"
else
    log_info "  Already running (socket: $DOCKER_SOCKET_PATH)"
fi

echo ""
log_info "=== Rootless Docker ready ==="
log_info "  Socket: $DOCKER_SOCKET_PATH"
log_info "  User:   $AGENT_USER (UID $AGENT_UID)"
