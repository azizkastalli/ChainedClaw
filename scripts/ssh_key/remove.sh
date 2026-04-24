#!/bin/bash
#
# Remove the openclaw SSH key from AGENT_USER's authorized_keys.
#
# Targets only the line carrying our "openclaw-agent-<host>" marker — does not
# touch any other keys the operator may have added for this user.
#
# Usage: remove.sh <host-name>
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

if [ ! -f "$ENV_FILE" ]; then
    echo "ERROR: .env file not found at $ENV_FILE"
    exit 1
fi
source "$ENV_FILE"

HOST_NAME="${1:-default}"
KEY_MARKER="openclaw-agent-${HOST_NAME}"

echo "=== Removing SSH key ==="
echo "  User:   $AGENT_USER"
echo "  Marker: $KEY_MARKER"

AUTH_KEYS="/home/$AGENT_USER/.ssh/authorized_keys"
if [ ! -f "$AUTH_KEYS" ]; then
    log_warn "No authorized_keys file at $AUTH_KEYS — nothing to remove"
    exit 0
fi

if grep -q " $KEY_MARKER\$" "$AUTH_KEYS" 2>/dev/null; then
    sed -i "/ $KEY_MARKER\$/d" "$AUTH_KEYS"
    log_info "Removed line with marker '$KEY_MARKER' from $AUTH_KEYS"
else
    log_warn "No line with marker '$KEY_MARKER' found in $AUTH_KEYS"
fi

echo ""
echo "=== SSH Key Removed ==="
echo "Run 'systemctl reload sshd' to apply changes."
