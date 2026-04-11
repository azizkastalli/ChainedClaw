#!/bin/bash
#
# Initialize Nginx basic auth for OpenClaw dashboard
# Generates htpasswd file with random password if not provided
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../../.env"

# Source .env if it exists
if [ -f "$ENV_FILE" ]; then
    source "$ENV_FILE"
fi

HTPASSWD_DIR="/etc/openclaw/nginx"
HTPASSWD_FILE="$HTPASSWD_DIR/.htpasswd"

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
    log_error "This script must be run as root (use )"
    exit 1
fi

echo "=== Initializing OpenClaw Dashboard Auth ==="
echo "  File: $HTPASSWD_FILE"
echo ""

# Create directory
mkdir -p "$HTPASSWD_DIR"

# Check for existing htpasswd file
if [ -f "$HTPASSWD_FILE" ]; then
    log_warn "htpasswd file already exists"
    read -p "Overwrite? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Keeping existing htpasswd file"
        exit 0
    fi
fi

# Check for apache2-utils (htpasswd command)
if ! command -v htpasswd &> /dev/null; then
    log_info "Installing apache2-utils for htpasswd..."
    apt-get update -qq && apt-get install -y -qq apache2-utils > /dev/null 2>&1
fi

# Generate random password if not set
if [ -z "${DASHBOARD_PASSWORD:-}" ]; then
    DASHBOARD_PASSWORD=$(openssl rand -base64 24)
    GENERATED=true
else
    GENERATED=false
fi

# Create htpasswd file
DASHBOARD_USER="${DASHBOARD_USER:-openclaw}"
echo "$DASHBOARD_PASSWORD" | htpasswd -i -c "$HTPASSWD_FILE" "$DASHBOARD_USER"

# Set permissions
chown root:root "$HTPASSWD_FILE"
chmod 644 "$HTPASSWD_FILE"

echo ""
log_info "htpasswd file created: $HTPASSWD_FILE"
echo ""
echo "=========================================="
echo "Dashboard Credentials"
echo "=========================================="
echo "  Username: $DASHBOARD_USER"
echo "  Password: $DASHBOARD_PASSWORD"
if [ "$GENERATED" = true ]; then
    echo ""
    log_warn "Password was auto-generated. Save it!"
    echo ""
    echo "Add to .env to persist:"
    echo "  DASHBOARD_USER=$DASHBOARD_USER"
    echo "  DASHBOARD_PASSWORD=$DASHBOARD_PASSWORD"
fi
echo "=========================================="
echo ""
echo "Dashboard will be available at: http://localhost:${NGINX_HTTP_PORT:-8090}"
