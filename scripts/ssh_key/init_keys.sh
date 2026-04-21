#!/bin/bash
#
# Initialize OpenClaw SSH keys in the project directory
# Keys are generated outside the container and mounted read-only
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

SSH_DIR="$PROJECT_ROOT/.ssh"
KEY_FILE="$SSH_DIR/id_agent"
KNOWN_HOSTS="$SSH_DIR/known_hosts"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

echo "=== Initializing SSH Keys ==="
echo "  Directory: $SSH_DIR"
echo ""

# Create .ssh directory
mkdir -p "$SSH_DIR"

# Create agent data directories if they don't exist
for _DATA_DIR in "$PROJECT_ROOT/.openclaw-data" "$PROJECT_ROOT/.claudecode-data" "$PROJECT_ROOT/.hermes-data"; do
    if [ ! -d "$_DATA_DIR" ]; then
        mkdir -p "$_DATA_DIR"
        log_info "Created $_DATA_DIR"
    fi
done
# Generate key if not exists
if [ ! -f "$KEY_FILE" ]; then
    log_info "Generating Ed25519 key..."
    ssh-keygen -t ed25519 -f "$KEY_FILE" -N "" -C "agent-dev"
    log_info "Key generated: $KEY_FILE"
else
    log_warn "Key already exists: $KEY_FILE"
    read -p "Regenerate? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        rm -f "$KEY_FILE" "$KEY_FILE.pub"
        ssh-keygen -t ed25519 -f "$KEY_FILE" -N "" -C "agent-dev"
        log_info "Key regenerated: $KEY_FILE"
    fi
fi

# Create known_hosts if not exists
if [ ! -f "$KNOWN_HOSTS" ]; then
    touch "$KNOWN_HOSTS"
    log_info "Created empty known_hosts file"
fi

# Set permissions
# Directory: world-traversable so container root (cap_drop:ALL) can enter it.
# Private key: group root (gid 0) + mode 640 so container root reads via group
#              membership without needing CAP_DAC_READ_SEARCH.
#              The entrypoint copies the key into tmpfs and chmod 600s the copy
#              before passing it to SSH, so SSH's strict-mode check still passes.
# Public key and known_hosts: world-readable (no secret).
chmod 755 "$SSH_DIR"
chmod 640 "$KEY_FILE"
chmod 644 "$KEY_FILE.pub"
chmod 644 "$KNOWN_HOSTS"

# Load agent UIDs from .env (OPENCLAW_UID, CLAUDECODE_UID, HERMES_UID).
# Defaults match official image UIDs and preserve existing behaviour when .env is absent.
if [ -f "$PROJECT_ROOT/.env" ]; then
    # shellcheck source=/dev/null
    source "$PROJECT_ROOT/.env"
fi
_OPENCLAW_UID="${OPENCLAW_UID:-1000}"
_CLAUDECODE_UID="${CLAUDECODE_UID:-1000}"
_HERMES_UID="${HERMES_UID:-10000}"

# Ownership: claudecode/node user owns key (reads via owner bit),
# openclaw root (gid 0) reads via group bit — no CAP_DAC_READ_SEARCH needed.
if [ "$EUID" -eq 0 ]; then
    chown "${_CLAUDECODE_UID}:0" "$SSH_DIR" "$KEY_FILE" "$KEY_FILE.pub" "$KNOWN_HOSTS"
    [ -d "$PROJECT_ROOT/.openclaw-data"  ] && chown "${_OPENCLAW_UID}:${_OPENCLAW_UID}"   "$PROJECT_ROOT/.openclaw-data"
    [ -d "$PROJECT_ROOT/.claudecode-data"] && chown "${_CLAUDECODE_UID}:${_CLAUDECODE_UID}" "$PROJECT_ROOT/.claudecode-data"
    [ -d "$PROJECT_ROOT/.hermes-data"    ] && chown "${_HERMES_UID}:${_HERMES_UID}"        "$PROJECT_ROOT/.hermes-data"
    log_info "Set ownership: SSH dir → uid ${_CLAUDECODE_UID}:gid 0; data dirs → respective UIDs"
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
