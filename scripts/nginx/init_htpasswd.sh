#!/bin/bash
#
# Initialize Nginx basic auth for OpenClaw dashboard
# Generates htpasswd file with random password if not provided
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/../.."
ENV_FILE="$PROJECT_DIR/.env"

# Source .env if it exists
if [ -f "$ENV_FILE" ]; then
    source "$ENV_FILE"
fi

HTPASSWD_DIR="$PROJECT_DIR/nginx"
HTPASSWD_FILE="$HTPASSWD_DIR/.htpasswd"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

echo "=== Initializing Dashboard Auth ==="
echo "  File: $HTPASSWD_FILE"
echo ""

# Create directory
mkdir -p "$HTPASSWD_DIR"

# If the file exists but is not writable (e.g. owned by root from an old sudo run), bail early
if [ -f "$HTPASSWD_FILE" ] && [ ! -w "$HTPASSWD_FILE" ]; then
    log_error "Cannot write to $HTPASSWD_FILE (permission denied)"
    log_error "Run the following to reset it, then re-run 'make auth':"
    echo ""
    echo "  sudo rm $HTPASSWD_FILE"
    echo ""
    exit 1
fi

# Check for apache2-utils (htpasswd command)
if ! command -v htpasswd &> /dev/null; then
    log_info "Installing apache2-utils for htpasswd..."
    sudo apt-get update -qq && sudo apt-get install -y -qq apache2-utils > /dev/null 2>&1
fi

# Generate random password if not set
if [ -z "${DASHBOARD_PASSWORD:-}" ]; then
    DASHBOARD_PASSWORD=$(openssl rand -base64 24)
    GENERATED=true
else
    GENERATED=false
fi

# Create htpasswd file (always overwrite)
DASHBOARD_USER="${DASHBOARD_USER:-agent-dev}"
echo "$DASHBOARD_PASSWORD" | htpasswd -i -c "$HTPASSWD_FILE" "$DASHBOARD_USER"

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
