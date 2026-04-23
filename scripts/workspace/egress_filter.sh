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
# Allowed: loopback, established connections, DNS, HTTPS to package registries.
# Everything else from AGENT_USER is dropped.
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

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
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
CHAIN="AGENT-WORKSPACE-EGRESS"

if [ "$FLUSH" = "--flush" ]; then
    echo "=== Removing egress filter for $AGENT_USER (UID $AGENT_UID) ==="
    iptables -D OUTPUT -j "$CHAIN" 2>/dev/null || true
    iptables -F "$CHAIN" 2>/dev/null || true
    iptables -X "$CHAIN" 2>/dev/null || true
    # Also clean up the legacy chroot-named chain from prior installs.
    iptables -D OUTPUT -j AGENT-CHROOT-EGRESS 2>/dev/null || true
    iptables -F AGENT-CHROOT-EGRESS 2>/dev/null || true
    iptables -X AGENT-CHROOT-EGRESS 2>/dev/null || true
    log_info "Egress filter removed"
    exit 0
fi

echo "=== Applying egress filter for $AGENT_USER (UID $AGENT_UID) ==="

if ! iptables -L "$CHAIN" -n &>/dev/null; then
    iptables -N "$CHAIN"
fi
iptables -F "$CHAIN"

# Loopback
iptables -A "$CHAIN" -o lo -j RETURN

# Established/return traffic (SSH sessions, pulled registry data, etc.)
iptables -A "$CHAIN" -m owner --uid-owner "$AGENT_UID" -m state --state ESTABLISHED,RELATED -j RETURN

# DNS
iptables -A "$CHAIN" -m owner --uid-owner "$AGENT_UID" -p udp --dport 53 -j RETURN
iptables -A "$CHAIN" -m owner --uid-owner "$AGENT_UID" -p tcp --dport 53 -j RETURN

# HTTPS to domains listed in config.json allowed_domains
CONFIG_JSON="$SCRIPT_DIR/../../config.json"
if [ ! -f "$CONFIG_JSON" ]; then
    log_error "config.json not found at $CONFIG_JSON — cannot build egress allowlist"
    exit 1
fi
while IFS= read -r domain; do
    [ -z "$domain" ] && continue
    ips=$(dig +short A "$domain" 2>/dev/null || true)
    for ip in $ips; do
        if [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            iptables -A "$CHAIN" -m owner --uid-owner "$AGENT_UID" -d "$ip" -p tcp --dport 443 -j RETURN
            log_info "  Allowed HTTPS to $domain ($ip)"
        fi
    done
done < <(python3 -c "
import json
with open('$CONFIG_JSON') as f:
    c = json.load(f)
for d in c.get('allowed_domains', []):
    print(d)
" 2>/dev/null)

# Default drop for AGENT_USER
iptables -A "$CHAIN" -m owner --uid-owner "$AGENT_UID" -j DROP

# Wire into OUTPUT once
if ! iptables -L OUTPUT -n | grep -q "$CHAIN"; then
    iptables -I OUTPUT 2 -j "$CHAIN"
fi

echo ""
log_info "Egress filter active (UID $AGENT_UID)"
log_info "  Allowed: loopback, established, DNS (53), HTTPS to registries"
log_info "  Blocked: all other outbound from $AGENT_USER"
log_info "To remove: $0 $HOST_NAME --flush"
