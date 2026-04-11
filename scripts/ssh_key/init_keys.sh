#!/bin/bash
#
# Initialize OpenClaw SSH keys in the project directory
# Keys are generated outside the container and mounted read-only
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

SSH_DIR="$PROJECT_ROOT/.ssh"
KEY_FILE="$SSH_DIR/id_openclaw"
KNOWN_HOSTS="$SSH_DIR/known_hosts"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

echo "=== Initializing OpenClaw SSH Keys ==="
echo "  Directory: $SSH_DIR"
echo ""

# Create .ssh directory
mkdir -p "$SSH_DIR"

# Also create .openclaw-data directory if it doesn't exist
OPENCLAW_DATA_DIR="$PROJECT_ROOT/.openclaw-data"
if [ ! -d "$OPENCLAW_DATA_DIR" ]; then
    mkdir -p "$OPENCLAW_DATA_DIR"
    log_info "Created $OPENCLAW_DATA_DIR"
fi

# Generate key if not exists
if [ ! -f "$KEY_FILE" ]; then
    log_info "Generating Ed25519 key..."
    ssh-keygen -t ed25519 -f "$KEY_FILE" -N "" -C "openclaw-agent"
    log_info "Key generated: $KEY_FILE"
else
    log_warn "Key already exists: $KEY_FILE"
    read -p "Regenerate? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        rm -f "$KEY_FILE" "$KEY_FILE.pub"
        ssh-keygen -t ed25519 -f "$KEY_FILE" -N "" -C "openclaw-agent"
        log_info "Key regenerated: $KEY_FILE"
    fi
fi

# Create known_hosts if not exists
if [ ! -f "$KNOWN_HOSTS" ]; then
    touch "$KNOWN_HOSTS"
    log_info "Created empty known_hosts file"
fi

# Set permissions
chmod 700 "$SSH_DIR"
chmod 600 "$KEY_FILE"
chmod 644 "$KEY_FILE.pub"
chmod 644 "$KNOWN_HOSTS"

# Fix ownership for Docker container (user 1000)
# When run with sudo, keys are created as root and container can't read them
if [ "$EUID" -eq 0 ]; then
    # Running as root (sudo) - set ownership to user 1000 for Docker
    chown -R 1000:1000 "$SSH_DIR"
    chown 1000:1000 "$OPENCLAW_DATA_DIR"
    log_info "Set ownership to UID 1000 for Docker container access"
else
    log_info "Ownership kept as current user (running without sudo)"
fi

echo ""
log_info "SSH key setup complete!"
echo ""
echo "Public key (add to target host authorized_keys):"
echo "----------------------------------------"
cat "$KEY_FILE.pub"
echo "----------------------------------------"
echo ""
echo "To pre-seed host keys (recommended for security):"
echo "  ssh-keyscan -H <hostname> >> $KNOWN_HOSTS"
echo ""
echo "Then start the container:"
echo "  docker compose up -d"
