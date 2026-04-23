#!/bin/bash
#
# UID-keyed egress filter for AGENT_USER on the remote host.
#
# The filter matches packets by their owning UID (-m owner --uid-owner), so it
# covers ALL processes running as AGENT_USER: the workspace container (rootless
# Docker runs as AGENT_USER, so container egress appears as AGENT_USER on the
# host), any Docker-in-Docker containers launched via the rootless daemon, and
# native processes on the host.
#
# How it works:
#   1. iptables nat OUTPUT redirects AGENT_USER's port 80/443 to a local
#      transparent proxy (egress_proxy.py, running as root on PROXY_PORT).
#   2. The proxy reads the TLS SNI (HTTPS) or Host header (HTTP), checks the
#      hostname against config.json allowed_domains, then tunnels or blocks.
#   3. The filter OUTPUT chain drops everything else from AGENT_USER (non-
#      web ports, raw TCP, etc.). DNS (53) is allowed.
#
# This restores hostname-based allowlisting without breaking CDN-backed
# registries (quay.io CDN subdomains, S3 presigned URLs, etc.), because the
# proxy matches on the SNI hostname — not the destination IP.
#
# Enable per-host by setting "egress_filter": true in config.json.
#
# Usage:
#   egress_filter.sh <host-name>          # Apply
#   egress_filter.sh <host-name> --flush  # Remove
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../../.env"
CONFIG_JSON="$SCRIPT_DIR/../../config.json"

PROXY_PORT=3129
PROXY_BIN="/usr/local/bin/openclaw-egress-proxy"
PROXY_LOG="/tmp/openclaw-egress-proxy.log"
FILTER_CHAIN="AGENT-WORKSPACE-EGRESS"
NAT_CHAIN="AGENT-EGRESS-NAT"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

if [ "$EUID" -ne 0 ]; then
    log_error "Must run as root (sudo)"
    exit 1
fi

if [ ! -f "$ENV_FILE" ]; then
    log_error ".env not found at $ENV_FILE"
    exit 1
fi
source "$ENV_FILE"

if [ -z "${1:-}" ]; then
    echo "Usage: $0 <host-name> [--flush]"
    exit 1
fi
HOST_NAME="$1"
FLUSH="${2:-}"

if ! id "$AGENT_USER" &>/dev/null; then
    log_error "User $AGENT_USER does not exist"
    exit 1
fi
AGENT_UID=$(id -u "$AGENT_USER")

# ── Flush ─────────────────────────────────────────────────────────────────────

if [ "$FLUSH" = "--flush" ]; then
    echo "=== Removing egress filter for $AGENT_USER (UID $AGENT_UID) ==="

    # Remove filter chain
    iptables -D OUTPUT -j "$FILTER_CHAIN" 2>/dev/null || true
    iptables -F "$FILTER_CHAIN" 2>/dev/null || true
    iptables -X "$FILTER_CHAIN" 2>/dev/null || true

    # Remove nat chain
    iptables -t nat -D OUTPUT -m owner --uid-owner "$AGENT_UID" -j "$NAT_CHAIN" 2>/dev/null || true
    iptables -t nat -F "$NAT_CHAIN" 2>/dev/null || true
    iptables -t nat -X "$NAT_CHAIN" 2>/dev/null || true

    # Stop the proxy
    pkill -f 'openclaw-egress-proxy' 2>/dev/null || true

    # Clean up legacy chain names from prior installs
    for legacy in AGENT-CHROOT-EGRESS; do
        iptables -D OUTPUT -j "$legacy" 2>/dev/null || true
        iptables -F "$legacy" 2>/dev/null || true
        iptables -X "$legacy" 2>/dev/null || true
    done

    log_info "Egress filter removed"
    exit 0
fi

# ── Apply ─────────────────────────────────────────────────────────────────────

echo "=== Applying egress filter for $AGENT_USER (UID $AGENT_UID) ==="

if [ ! -f "$CONFIG_JSON" ]; then
    log_error "config.json not found at $CONFIG_JSON"
    exit 1
fi

# ── 1. Install and start the egress proxy ─────────────────────────────────────

log_info "[1/3] Starting egress proxy (port $PROXY_PORT)..."
install -m 0755 "$SCRIPT_DIR/egress_proxy.py" "$PROXY_BIN"

# Stop any existing instance before (re)starting
pkill -f 'openclaw-egress-proxy' 2>/dev/null || true
sleep 0.3

nohup python3 "$PROXY_BIN" "$PROXY_PORT" "$CONFIG_JSON" \
    </dev/null >>"$PROXY_LOG" 2>&1 &

# Wait up to 5 s for the proxy to bind its port
for _ in $(seq 1 10); do
    python3 -c "
import socket, sys
s = socket.socket()
s.settimeout(0.5)
try:
    s.connect(('127.0.0.1', $PROXY_PORT))
    s.close()
    sys.exit(0)
except Exception:
    sys.exit(1)
" 2>/dev/null && break
    sleep 0.5
done

if ! python3 -c "
import socket, sys
s = socket.socket()
s.settimeout(1)
try:
    s.connect(('127.0.0.1', $PROXY_PORT))
    s.close()
    sys.exit(0)
except Exception:
    sys.exit(1)
" 2>/dev/null; then
    log_error "Egress proxy failed to start. Check $PROXY_LOG"
    exit 1
fi

log_info "  Proxy listening on 127.0.0.1:$PROXY_PORT"
log_info "  Log: $PROXY_LOG"

# ── 2. Set up filter chain ────────────────────────────────────────────────────

log_info "[2/3] Applying filter chain rules..."

if ! iptables -L "$FILTER_CHAIN" -n &>/dev/null; then
    iptables -N "$FILTER_CHAIN"
fi
iptables -F "$FILTER_CHAIN"

# Loopback — includes redirected 80/443 traffic going to the proxy
iptables -A "$FILTER_CHAIN" -o lo -j RETURN

# Established/related return traffic
iptables -A "$FILTER_CHAIN" -m owner --uid-owner "$AGENT_UID" \
    -m state --state ESTABLISHED,RELATED -j RETURN

# DNS
iptables -A "$FILTER_CHAIN" -m owner --uid-owner "$AGENT_UID" \
    -p udp --dport 53 -j RETURN
iptables -A "$FILTER_CHAIN" -m owner --uid-owner "$AGENT_UID" \
    -p tcp --dport 53 -j RETURN

# Drop everything else from AGENT_USER.
# Port 80/443 is handled by the nat REDIRECT below — it goes to loopback
# (caught by the -o lo rule above) before it can reach this DROP.
iptables -A "$FILTER_CHAIN" -m owner --uid-owner "$AGENT_UID" -j DROP

# Wire filter chain into OUTPUT once
if ! iptables -L OUTPUT -n | grep -q "$FILTER_CHAIN"; then
    iptables -I OUTPUT 2 -j "$FILTER_CHAIN"
fi

# ── 3. Set up nat REDIRECT ────────────────────────────────────────────────────

log_info "[3/3] Applying nat REDIRECT rules..."

if ! iptables -t nat -L "$NAT_CHAIN" -n &>/dev/null; then
    iptables -t nat -N "$NAT_CHAIN"
fi
iptables -t nat -F "$NAT_CHAIN"

iptables -t nat -A "$NAT_CHAIN" -p tcp --dport 443 -j REDIRECT --to-ports "$PROXY_PORT"
iptables -t nat -A "$NAT_CHAIN" -p tcp --dport 80  -j REDIRECT --to-ports "$PROXY_PORT"

# Wire nat chain into OUTPUT once (must match on AGENT_UID to avoid redirecting
# the proxy's own outbound connections — proxy runs as root)
if ! iptables -t nat -L OUTPUT -n | grep -q "$NAT_CHAIN"; then
    iptables -t nat -I OUTPUT 1 -m owner --uid-owner "$AGENT_UID" -j "$NAT_CHAIN"
fi

echo ""
log_info "Egress filter active (UID $AGENT_UID)"
log_info "  Port 80/443: REDIRECT → proxy → hostname check → tunnel or block"
log_info "  DNS (53): allowed directly"
log_info "  All other ports: dropped"
log_info "  Allowed domains: $(python3 -c "
import json
with open('$CONFIG_JSON') as f:
    c = json.load(f)
print(', '.join(c.get('allowed_domains', [])))
" 2>/dev/null)"
log_info "To remove: $0 $HOST_NAME --flush"
