#!/bin/bash
#
# OpenClaw Uninstallation Script
# Removes containers, chroot jails, SSH keys, and data directories
# Keeps Docker images for potential reinstallation
#
# Don't use set -e here - we want to continue even if some cleanup steps fail
set -uo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Track if we need to reload sshd
NEED_SSHD_RELOAD=false

# Confirm uninstallation
confirm_uninstall() {
    echo ""
    echo "========================================"
    echo "  OpenClaw Uninstallation Script"
    echo "========================================"
    echo ""
    echo "This will remove:"
    echo "  - Docker containers (agent-dev, agent-dev-nginx)"
    echo "  - Docker volumes"
    echo "  - Chroot jails for all configured hosts"
    echo "  - SSH keys (project .ssh/ directory)"
    echo "  - Dashboard auth (nginx/.htpasswd)"
    echo "  - Project .ssh directory"
    echo ""
    echo "This will NOT remove:"
    echo "  - Docker images (kept for reinstallation)"
    echo "  - .env and config.json files"
    echo "  - Agent data directories (.openclaw-data, .claudecode-data, .hermes-data)"
    echo "    Use 'make purge-data' to remove agent data"
    echo ""
    
    read -p "Are you sure you want to uninstall? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Uninstallation cancelled."
        exit 0
    fi
}

# Get list of configured hosts
get_configured_hosts() {
    if [ -f "$PROJECT_ROOT/config.json" ]; then
        # Use /usr/bin/python3 explicitly to ensure it works with 
        /usr/bin/python3 -c "
import json
import sys
try:
    with open('$PROJECT_ROOT/config.json', 'r') as f:
        config = json.load(f)
    for host in config.get('ssh_hosts', []):
        print(host.get('name', ''))
except Exception:
    pass
" 2>/dev/null
    fi
}

# Tear down chroot for all configured hosts
teardown_chroot() {
    log_step "Tearing down chroot jails..."
    
    HOSTS=$(get_configured_hosts)
    
    if [ -z "$HOSTS" ]; then
        log_info "No hosts found in config.json. Checking for existing chroot..."
        # Try to detect existing chroot from .env
        if [ -f "$PROJECT_ROOT/.env" ]; then
            source "$PROJECT_ROOT/.env"
            if [ -n "${CHROOT_BASE:-}" ] && [ -d "$CHROOT_BASE" ]; then
                log_info "Found chroot at $CHROOT_BASE"
                # Try to clean up using jail_break.sh with a dummy host
                # This is a fallback - jail_break.sh should handle partial cleanup
                log_warn "Manual cleanup may be required for $CHROOT_BASE"
            fi
        fi
        return 0
    fi
    
    for HOST in $HOSTS; do
        if [ -n "$HOST" ]; then
            log_info "Tearing down chroot for host: $HOST"
            if [ -f "$SCRIPT_DIR/chroot_jail/jail_break.sh" ]; then
                # Use set +e to prevent script exit on jail_break failure
                set +e
                 bash "$SCRIPT_DIR/chroot_jail/jail_break.sh" "$HOST"
                result=$?
                set -e
                if [ $result -eq 0 ]; then
                    NEED_SSHD_RELOAD=true
                else
                    log_warn "Failed to tear down chroot for $HOST (exit code: $result)"
                fi
            fi
        fi
    done
    
    log_info "Chroot teardown complete"
}

# Stop and remove Docker containers
remove_containers() {
    log_step "Stopping and removing Docker containers..."
    
    cd "$PROJECT_ROOT"
    
    # Stop containers and remove volumes
    if docker ps -a | grep -q "agent-dev\|openclaw"; then
        docker compose down -v
        log_info "Containers and volumes stopped and removed"
    else
        log_info "No containers found"
    fi
    
    # Remove any orphaned Docker volumes
    log_info "Checking for orphaned Docker volumes..."
    docker volume ls -q | grep "agent-dev\|openclaw" | xargs -r docker volume rm 2>/dev/null || true
    
    log_info "Docker cleanup complete"
}

# Remove SSH keys
remove_ssh_keys() {
    log_step "Removing SSH keys..."
    
    # Remove project .ssh directory
    if [ -d "$PROJECT_ROOT/.ssh" ]; then
        rm -rf "$PROJECT_ROOT/.ssh"
        log_info "Removed $PROJECT_ROOT/.ssh"
    fi
    
    log_info "SSH keys removed"
}

# Remove dashboard auth
remove_dashboard_auth() {
    log_step "Removing dashboard authentication..."

    if [ -f "$PROJECT_ROOT/nginx/.htpasswd" ]; then
        rm -f "$PROJECT_ROOT/nginx/.htpasswd"
        log_info "Removed $PROJECT_ROOT/nginx/.htpasswd"
    fi

    log_info "Dashboard auth removed"
}

# Remove data directory
remove_data() {
    log_step "Removing data directories..."
    
    # Remove agent data directories
    for _DATA_DIR in "$PROJECT_ROOT/.openclaw-data" "$PROJECT_ROOT/.claudecode-data" "$PROJECT_ROOT/.hermes-data"; do
        if [ -d "$_DATA_DIR" ]; then
            rm -rf "$_DATA_DIR"
            log_info "Removed $_DATA_DIR"
        fi
    done
    
    log_info "Data directories removed"
}

# Reload sshd if needed
reload_sshd() {
    if [ "$NEED_SSHD_RELOAD" = true ]; then
        log_step "Reloading SSH daemon..."
         systemctl reload sshd || log_warn "Failed to reload sshd"
        log_info "SSHD reloaded"
    fi
}

# Show summary
show_summary() {
    echo ""
    log_info "=== Uninstallation Complete ==="
    echo ""
    echo "Removed:"
    echo "  ✓ Docker containers and volumes"
    echo "  ✓ Chroot jails"
    echo "  ✓ SSH keys"
    echo "  ✓ Dashboard authentication"
    echo ""
    echo "Kept:"
    echo "  • Docker images (use 'docker image prune' to remove)"
    echo "  • Configuration files (.env, config.json)"
    echo "  • Agent data directories (.openclaw-data, .claudecode-data, .hermes-data)"
    echo "    Use 'make purge-data' to remove agent data"
    echo ""
    echo "To reinstall, run:"
    echo "   make up AGENT=openclaw"
    echo ""
}

# Main uninstallation flow
main() {
    confirm_uninstall
    
    teardown_chroot
    remove_containers
    remove_ssh_keys
    remove_dashboard_auth
    reload_sshd
    show_summary
}

# Run main
main "$@"
