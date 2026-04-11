#!/bin/bash
#
# OpenClaw Installation Script
# Sets up containers, SSH keys, and chroot jail for all configured hosts
#
set -euo pipefail

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

# Check for required files
check_prerequisites() {
    log_step "Checking prerequisites..."
    
    # Check for .env
    if [ ! -f "$PROJECT_ROOT/.env" ]; then
        if [ -f "$PROJECT_ROOT/.env.example" ]; then
            log_info "Copying .env.example to .env"
            cp "$PROJECT_ROOT/.env.example" "$PROJECT_ROOT/.env"
            log_warn "Please edit $PROJECT_ROOT/.env with your settings"
        else
            log_error ".env file not found. Please create it from .env.example"
            exit 1
        fi
    fi
    
    # Check for config.json
    if [ ! -f "$PROJECT_ROOT/config.json" ]; then
        if [ -f "$PROJECT_ROOT/config.example.json" ]; then
            log_info "Copying config.example.json to config.json"
            cp "$PROJECT_ROOT/config.example.json" "$PROJECT_ROOT/config.json"
            log_warn "Please edit $PROJECT_ROOT/config.json with your SSH host details"
        else
            log_error "config.json file not found. Please create it from config.example.json"
            exit 1
        fi
    fi
    
    # Source .env for configuration
    source "$PROJECT_ROOT/.env"
    
    # Check for docker
    if ! command -v docker &> /dev/null; then
        log_error "Docker is not installed. Please install Docker first."
        exit 1
    fi
    
    # Check for docker compose
    if ! docker compose version &> /dev/null; then
        log_error "Docker Compose is not installed. Please install Docker Compose first."
        exit 1
    fi
    
    log_info "Prerequisites check passed"
}

# Initialize SSH keys
init_ssh_keys() {
    log_step "Initializing SSH keys..."
    
    if [ -f "$PROJECT_ROOT/.ssh/id_openclaw" ]; then
        log_info "SSH keys already exist at $PROJECT_ROOT/.ssh/"
    else
        bash "$SCRIPT_DIR/ssh_key/init_keys.sh"
    fi
    
    log_info "SSH keys ready"
}

# Initialize dashboard auth
init_dashboard_auth() {
    log_step "Initializing dashboard authentication..."
    
    if [ -f "/etc/openclaw/nginx/.htpasswd" ]; then
        log_info "Dashboard auth already exists at /etc/openclaw/nginx/.htpasswd"
    else
         bash "$SCRIPT_DIR/nginx/init_htpasswd.sh"
    fi
    
    log_info "Dashboard auth ready"
}

# Start Docker containers
start_containers() {
    log_step "Starting Docker containers..."
    
    cd "$PROJECT_ROOT"
    docker compose up -d
    
    log_info "Containers started"
    
    # Wait for container to be ready
    log_info "Waiting for container to be ready..."
    sleep 3
    
    # Check if container is running
    if ! docker ps | grep -q openclaw; then
        log_error "Container failed to start. Check logs with: docker logs openclaw"
        exit 1
    fi
    
    log_info "Container is running"
}

# Setup chroot for all configured hosts
setup_chroot() {
    log_step "Setting up chroot jails for configured hosts..."
    
    # Get list of host names from config.json
    # Use /usr/bin/python3 explicitly to ensure it works with 
    HOSTS=$(/usr/bin/python3 -c "
import json
import sys
try:
    with open('$PROJECT_ROOT/config.json', 'r') as f:
        config = json.load(f)
    for host in config.get('ssh_hosts', []):
        print(host.get('name', ''))
except Exception as e:
    print('', file=sys.stderr)
    sys.exit(1)
" 2>/dev/null)
    
    if [ -z "$HOSTS" ]; then
        log_warn "No hosts found in config.json. Skipping chroot setup."
        log_warn "You can set up chroot manually with:  bash scripts/chroot_jail/jail_set.sh <host-name>"
        return 0
    fi
    
    for HOST in $HOSTS; do
        if [ -n "$HOST" ]; then
            log_info "Setting up chroot for host: $HOST"
             bash "$SCRIPT_DIR/chroot_jail/jail_set.sh" "$HOST"
        fi
    done
    
    log_info "Chroot setup complete"
}

# Reload sshd
reload_sshd() {
    log_step "Reloading SSH daemon..."
    
    if  systemctl reload sshd; then
        log_info "SSHD reloaded successfully"
    else
        log_warn "Failed to reload sshd. You may need to run:  systemctl reload sshd"
    fi
}

# Verify installation
verify_installation() {
    log_step "Verifying installation..."
    
    echo ""
    log_info "=== Installation Summary ==="
    log_info "  Project root: $PROJECT_ROOT"
    log_info "  SSH keys: $PROJECT_ROOT/.ssh/"
    log_info "  Dashboard auth: /etc/openclaw/nginx/.htpasswd"
    log_info "  Containers: openclaw, openclaw-nginx"
    echo ""
    
    # Get first host for testing
    FIRST_HOST=$(/usr/bin/python3 -c "
import json
with open('$PROJECT_ROOT/config.json', 'r') as f:
    config = json.load(f)
hosts = config.get('ssh_hosts', [])
if hosts:
    print(hosts[0].get('name', ''))
" 2>/dev/null)
    
    if [ -n "$FIRST_HOST" ]; then
        log_info "Testing SSH connection to $FIRST_HOST..."
        if docker exec openclaw ssh -o BatchMode=yes -o ConnectTimeout=5 "$FIRST_HOST" whoami 2>/dev/null; then
            log_info "SSH connection successful!"
        else
            log_warn "SSH connection test failed. This may be normal if the host is not reachable."
            log_warn "Test manually with: docker exec -it openclaw ssh $FIRST_HOST"
        fi
    fi
    
    echo ""
    log_info "=== Installation Complete ==="
    log_info "Dashboard: http://localhost:${NGINX_HTTP_PORT:-8090}"
    log_info "Test SSH:  docker exec -it openclaw ssh <host-name>"
    echo ""
}

# Main installation flow
main() {
    echo ""
    echo "========================================"
    echo "  OpenClaw Installation Script"
    echo "========================================"
    echo ""
    
    check_prerequisites
    init_ssh_keys
    init_dashboard_auth
    start_containers
    setup_chroot
    reload_sshd
    verify_installation
}

# Run main
main "$@"
