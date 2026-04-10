#!/bin/bash
#
# Initialize OpenClaw SSH keys on the host
# Keys are generated outside the container and mounted read-only
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../.env"

# Source .env if it exists
if [ -f "$ENV_FILE" ]; then
    source "$ENV_FILE"
fi

SSH_DIR="/etc/openclaw/ssh"
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

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    log_error "This script must be run as root (use sudo)"
    exit 1
fi

echo "=== Initializing OpenClaw SSH Keys ==="
echo "  Directory: $SSH_DIR"
echo ""

# Create directory
mkdir -p "$SSH_DIR"

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
chown -R root:root "$SSH_DIR"
chmod 700 "$SSH_DIR"
chmod 600 "$KEY_FILE"
chmod 644 "$KEY_FILE.pub"
chmod 644 "$KNOWN_HOSTS"

echo ""
log_info "SSH key setup complete!"
echo ""
echo "Public key (add to target host authorized_keys):"
echo "----------------------------------------"
cat "$KEY_FILE.pub"
echo "----------------------------------------"
echo ""
echo "To pre-seed host keys (recommended for security):"
echo "  sudo ssh-keyscan -H <hostname> >> $KNOWN_HOSTS"
echo ""
echo "Then start the container:"
echo "  docker compose up -d"
