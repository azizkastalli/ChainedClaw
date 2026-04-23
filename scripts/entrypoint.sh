#!/bin/bash
#
# Agent container entrypoint — runs as root, drops to AGENT_USER before exec.
#
# Root phase (requires NET_ADMIN/NET_RAW/SETUID/SETGID in cap_add):
#   1. Run init-firewall.sh (iptables — needs NET_ADMIN/NET_RAW)
#   2. Validate SSH key
#   3. Set up writable ~/.ssh in tmpfs (copy key, generate config, scan known_hosts)
#   4. Chown ~/.ssh to AGENT_USER
#
# Agent phase (runs as AGENT_USER via gosu — no effective capabilities):
#   5. Start ssh-agent as AGENT_USER (socket owned by AGENT_USER)
#   6. Load SSH key, lock key file (chmod 000)
#   7. exec AGENT_CMD
#
set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# ── 1. Internal firewall ────────────────────────────────────────────────────────
# Must run as root (needs NET_ADMIN/NET_RAW). Restricts outbound to allowed domains.
if [ -x /usr/local/bin/init-firewall.sh ]; then
    log_info "Starting internal firewall..."
    /usr/local/bin/init-firewall.sh
else
    log_warn "init-firewall.sh not found — container egress unrestricted"
fi

# ── 2. Define paths ────────────────────────────────────────────────────────────
HOME_DIR="${HOME:-/home/agent-dev}"
SSH_KEYS_DIR="$HOME_DIR/.ssh-keys"   # Read-only bind mount: actual keys from host
SSH_DIR="$HOME_DIR/.ssh"              # Writable tmpfs: config, key copy, known_hosts
KEY_SOURCE="$SSH_KEYS_DIR/id_agent"  # Private key in read-only source mount
AGENT_USER="${AGENT_USER:-root}"
export CONFIG_JSON="/config.json"

# ── 3. Validate SSH key ────────────────────────────────────────────────────────
if [ ! -f "$KEY_SOURCE" ]; then
    log_error "============================================"
    log_error "SSH key not found at $KEY_SOURCE"
    log_error "============================================"
    log_error ""
    log_error "Run on the host:  make keys"
    log_error "Then restart:     make up AGENT=<name>"
    log_error "============================================"
    exit 1
fi
log_info "SSH key found at $KEY_SOURCE (read-only, host-managed)"

# ── 4. Set up writable SSH working directory ───────────────────────────────────
# SSH follows mode rules strictly: config and keys must not be group/world writable.
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR" 2>/dev/null || true

# Copy private key to writable tmpfs so we can chmod 600 (source may be 640).
# SSH refuses keys with group-readable bits set.
cp "$KEY_SOURCE" "$SSH_DIR/id_agent"
chmod 600 "$SSH_DIR/id_agent"
ln -sf "${KEY_SOURCE}.pub" "$SSH_DIR/id_agent.pub" 2>/dev/null || true

# Copy known_hosts (not symlinked — entrypoint may append on first boot)
if [ -f "$SSH_KEYS_DIR/known_hosts" ] && [ ! -f "$SSH_DIR/known_hosts" ]; then
    cp "$SSH_KEYS_DIR/known_hosts" "$SSH_DIR/known_hosts"
fi
touch "$SSH_DIR/known_hosts" 2>/dev/null || true

# Export for Python scripts below
export KEY_FILE="$SSH_DIR/id_agent"
export SSH_DIR

# ── 5. Generate SSH config from config.json ────────────────────────────────────
log_info "Creating SSH config..."

if ! python3 << 'PYTHON_EOF' > "$SSH_DIR/config"
import json
import os
import sys

CONFIG_JSON = os.environ.get('CONFIG_JSON', '/config.json')
KEY_FILE    = os.environ.get('KEY_FILE',    '/home/agent-dev/.ssh/id_agent')

try:
    with open(CONFIG_JSON, 'r') as f:
        config = json.load(f)

    print("# Auto-generated SSH config — do not edit (regenerated on each container start)")
    print("")

    for host in config.get('ssh_hosts', []):
        name         = host.get('name', 'unknown')
        hostname     = host.get('hostname', '')
        port         = host.get('port', 22)
        user         = host.get('user', 'root')
        strict_check = host.get('strict_host_key_checking', True)
        isolation    = host.get('isolation', 'container')
        paths        = host.get('project_paths', [])

        print(f"Host {name}")
        print(f"    HostName {hostname}")
        print(f"    Port {port}")
        print(f"    User {user}")
        print(f"    IdentityFile {KEY_FILE}")
        print(f"    StrictHostKeyChecking {'yes' if strict_check else 'no'}")

        if paths:
            if isolation == 'container':
                for p in paths:
                    print(f"    # workspace: ~/workspace/{os.path.basename(p)}")
            else:
                for p in paths:
                    print(f"    # path: {p}")

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

chmod 600 "$SSH_DIR/config" 2>/dev/null || true
log_info "SSH config generated"

# ── 6. Pre-seed known_hosts ────────────────────────────────────────────────────
log_info "Checking known_hosts..."
KNOWN_HOSTS="$SSH_DIR/known_hosts"

_should_scan=true
if [ -s "$KNOWN_HOSTS" ]; then
    log_info "known_hosts already has entries — skipping ssh-keyscan"
    _should_scan=false
fi

if [ "$_should_scan" = true ]; then
    log_warn "=============================================="
    log_warn "SECURITY: Running ssh-keyscan (MITM risk)"
    log_warn "Pre-seed known_hosts on the host to skip this:"
    log_warn "  ssh-keyscan -H <hostname> >> .ssh/known_hosts"
    log_warn "=============================================="
    python3 << 'PYTHON_EOF2' || log_warn "known_hosts pre-seed incomplete (host may be unreachable)"
import json, os, subprocess, sys

CONFIG_JSON = os.environ.get('CONFIG_JSON', '/config.json')
SSH_DIR     = os.environ.get('SSH_DIR',     '/home/agent-dev/.ssh')
known_hosts = os.path.join(SSH_DIR, 'known_hosts')

try:
    with open(CONFIG_JSON, 'r') as f:
        config = json.load(f)
    with open(known_hosts, 'a') as kh:
        for host in config.get('ssh_hosts', []):
            hostname = host.get('hostname', '')
            port     = str(host.get('port', 22))
            if hostname:
                cmd    = ['ssh-keyscan', '-T', '5', '-p', port, hostname]
                result = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
                if result.stdout.strip():
                    kh.write(result.stdout)
                    print(f"  Pinned host key for {hostname}:{port}")
                else:
                    print(f"  Warning: could not scan {hostname}:{port}", file=sys.stderr)
except Exception as e:
    print(f"  Warning: known_hosts pre-seed failed: {e}", file=sys.stderr)
PYTHON_EOF2
fi

chmod 644 "$KNOWN_HOSTS" 2>/dev/null || true

# ── 7. Hand SSH dir to agent user ──────────────────────────────────────────────
# tmpfs mounts are root:root by default. Chown before dropping privileges so the
# agent user can read/write their own directories.
if [ "$AGENT_USER" != "root" ]; then
    chown -R "$AGENT_USER" "$SSH_DIR"
    log_info "SSH dir handed to $AGENT_USER"

    # ── 7b. Hand config dir to agent user ──────────────────────────────────────
    # Bind-mounted config directories may be owned by root or host user.
    # Chown so the agent can write its config files (e.g., ~/.openclaw/openclaw.json).
    # Note: chown may fail if we lack CAP_DAC_OVERRIDE and the dir is 0700 owned by
    # another user - that's fine, it means the agent user already owns it (UID match).
    AGENT_CONFIG_DIR="${APP_HOME:-$HOME_DIR}/.openclaw"
    if [ -d "$AGENT_CONFIG_DIR" ]; then
        chown -R "$AGENT_USER" "$AGENT_CONFIG_DIR" 2>/dev/null || true
        log_info "Config dir handed to $AGENT_USER: $AGENT_CONFIG_DIR"
    fi
fi

# ── 8. Summary ─────────────────────────────────────────────────────────────────
echo ""
log_info "============================================"
log_info "SSH Bridge Ready"
log_info "  User (agent): $AGENT_USER"
log_info "  Home:         $HOME_DIR"
log_info "  SSH dir:      $SSH_DIR"
log_info "  Key:          $KEY_FILE (→ $SSH_KEYS_DIR/id_agent)"
log_info "============================================"
echo ""

# ── 9. Drop privileges and launch agent ────────────────────────────────────────
# gosu switches from root to AGENT_USER (needs SETUID/SETGID in cap_add).
# After exec, Linux clears all effective capabilities for the non-root process —
# NET_ADMIN, SETUID, SETGID are gone. The agent runs fully unprivileged.
#
# ssh-agent is started inside the gosu'd context so its socket is owned by
# AGENT_USER (not root) and accessible to the agent process.
AGENT_CMD="${AGENT_CMD:-openclaw gateway run --allow-unconfigured}"
log_info "Dropping to user '$AGENT_USER' and starting agent: $AGENT_CMD"

if [ "$AGENT_USER" = "root" ]; then
    # No privilege drop needed — start ssh-agent and exec directly.
    if command -v ssh-agent &>/dev/null && command -v ssh-add &>/dev/null; then
        eval "$(ssh-agent -s)" >/dev/null 2>&1
        if ssh-add "$SSH_DIR/id_agent" >/dev/null 2>&1; then
            export SSH_AUTH_SOCK
            chmod 000 "$SSH_DIR/id_agent" 2>/dev/null || true
            log_info "SSH key loaded into ssh-agent (key file locked)"
        else
            log_error "ssh-add failed — key may not be readable"
        fi
    fi
    eval exec "$AGENT_CMD"
else
    # Drop to AGENT_USER via gosu. Start ssh-agent as that user so the socket
    # is accessible. $SSH_DIR and $AGENT_CMD are inherited via the environment.
    exec gosu "$AGENT_USER" bash -c '
        if command -v ssh-agent &>/dev/null && command -v ssh-add &>/dev/null; then
            eval "$(ssh-agent -s)" >/dev/null 2>&1
            if ssh-add "$SSH_DIR/id_agent" >/dev/null 2>&1; then
                export SSH_AUTH_SOCK
                chmod 000 "$SSH_DIR/id_agent" 2>/dev/null || true
                echo -e "\033[0;32m[INFO]\033[0m SSH key loaded into ssh-agent (key file locked)"
            else
                echo -e "\033[0;31m[ERROR]\033[0m ssh-add failed — key may not be readable by $USER"
            fi
        else
            echo -e "\033[1;33m[WARN]\033[0m ssh-agent not available — private key remains readable"
        fi
        eval exec "$AGENT_CMD"
    '
fi
