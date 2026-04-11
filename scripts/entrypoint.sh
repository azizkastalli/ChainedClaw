#!/bin/bash
#
# OpenClaw container entrypoint
# - Validates SSH key mount (keys are generated outside container)
# - Generates SSH config from config.json
# - Pre-seeds known_hosts (with MITM warning)
# - Hands off to OpenClaw gateway
#
set -uo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# 1. Define paths (non-root user)
HOME_DIR="${HOME:-/home/openclaw}"
SSH_DIR="$HOME_DIR/.ssh"
KEY_FILE="$SSH_DIR/id_openclaw"
CONFIG_FILE="$SSH_DIR/config"
export CONFIG_JSON="/config.json"

# 2. Check if SSH key exists (should be mounted read-only from host)
if [ ! -f "$KEY_FILE" ]; then
    log_error "============================================"
    log_error "SSH key not found at $KEY_FILE"
    log_error "============================================"
    log_error ""
    log_error "Keys must be generated on the HOST before starting the container."
    log_error ""
    log_error "Run on the host:"
    log_error "  ssh-keygen -t ed25519 -f .ssh/id_openclaw -N \"\" -C \"openclaw-agent\""
    log_error ""
    log_error "Then restart the container:"
    log_error "  docker compose down && docker compose up -d"
    log_error "============================================"
    exit 1
fi

log_info "SSH key found at $KEY_FILE"

# Check if key is read-only (expected for host-managed keys)
if [ -w "$KEY_FILE" ]; then
    log_warn "SSH key is writable inside container (expected for legacy setup)"
    log_warn "For better security, use host-side key management with read-only mount"
else
    log_info "SSH key is read-only (host-managed)"
fi

# 3. Create .ssh directory if needed
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

# 4. Generate SSH config from config.json
log_info "Creating SSH config file..."

if ! python3 << 'PYTHON_EOF' > "$CONFIG_FILE"
import json
import os
import sys

CONFIG_JSON = os.environ.get('CONFIG_JSON', '/config.json')
KEY_FILE = os.environ.get('KEY_FILE', '/home/openclaw/.ssh/id_openclaw')

try:
    with open(CONFIG_JSON, 'r') as f:
        config = json.load(f)
    
    print("# Auto-generated SSH config from config.json")
    print("# Keys are managed externally (read-only mount)")
    print("")
    
    if 'ssh_hosts' in config:
        for host in config['ssh_hosts']:
            name = host.get('name', 'unknown')
            hostname = host.get('hostname', '')
            port = host.get('port', 22)
            user = host.get('user', 'root')
            strict_check = host.get('strict_host_key_checking', True)
            
            print(f"Host {name}")
            print(f"    HostName {hostname}")
            print(f"    Port {port}")
            print(f"    User {user}")
            print(f"    IdentityFile {KEY_FILE}")
            print(f"    StrictHostKeyChecking {'yes' if strict_check else 'no'}")
            print("")
except FileNotFoundError:
    print(f"# Config file not found: {CONFIG_JSON}", file=sys.stderr)
    sys.exit(1)
except Exception as e:
    print(f"# Error parsing config: {e}", file=sys.stderr)
    sys.exit(1)
PYTHON_EOF
then
    log_error "SSH config generation failed!"
    exit 1
fi

log_info "SSH config generated"

# 5. Pre-seed known_hosts for configured hosts
echo ""
log_warn "=============================================="
log_warn "SECURITY WARNING: Host Key Pinning"
log_warn "=============================================="
log_warn "Host keys will be fetched via ssh-keyscan."
log_warn "This is vulnerable to MITM on first connection."
log_warn ""
log_warn "For high-security environments, pre-seed manually:"
log_warn "  ssh-keyscan -H <hostname> >> .ssh/known_hosts"
log_warn "=============================================="
echo ""

log_info "Pre-seeding known_hosts..."
KNOWN_HOSTS="$SSH_DIR/known_hosts"

# Check if known_hosts is mounted from host
if [ -f "$KNOWN_HOSTS" ] && [ ! -w "$KNOWN_HOSTS" ]; then
    log_info "known_hosts is read-only mount, skipping ssh-keyscan"
else
    python3 << 'PYTHON_EOF2' || log_warn "known_hosts pre-seed incomplete (host may be unreachable)"
import json, os, subprocess, sys

CONFIG_JSON = os.environ.get('CONFIG_JSON', '/config.json')
SSH_DIR = os.environ.get('SSH_DIR', '/home/openclaw/.ssh')
known_hosts = os.path.join(SSH_DIR, 'known_hosts')

try:
    with open(CONFIG_JSON, 'r') as f:
        config = json.load(f)
    with open(known_hosts, 'a') as kh:
        for host in config.get('ssh_hosts', []):
            hostname = host.get('hostname', '')
            if hostname:
                result = subprocess.run(
                    ['ssh-keyscan', '-T', '5', hostname],
                    capture_output=True, text=True, timeout=10
                )
                if result.stdout.strip():
                    kh.write(result.stdout)
                    print(f"  Pinned host key for {hostname}")
                else:
                    print(f"  Warning: Could not scan {hostname}", file=sys.stderr)
except Exception as e:
    print(f"  Warning: known_hosts pre-seed failed: {e}", file=sys.stderr)
PYTHON_EOF2
fi

chmod 644 "$KNOWN_HOSTS" 2>/dev/null || true

# 6. Apply permissions
log_info "Setting permissions..."
chmod 700 "$SSH_DIR" 2>/dev/null || true
chmod 600 "$KEY_FILE" 2>/dev/null || true
chmod 644 "$KEY_FILE.pub" 2>/dev/null || true
chmod 600 "$CONFIG_FILE" 2>/dev/null || true

# 7. Display configuration summary
echo ""
log_info "============================================"
log_info "SSH Bridge Configuration"
log_info "============================================"
log_info "  User:      $(id)"
log_info "  Home:      $HOME_DIR"
log_info "  SSH dir:   $SSH_DIR"
log_info "  Key file:  $KEY_FILE"
log_info "============================================"
echo ""

# 8. Hands off to the original OpenClaw start command
log_info "SSH bridge ready. Starting OpenClaw..."
exec openclaw gateway run --allow-unconfigured
