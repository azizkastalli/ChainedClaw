#!/bin/bash
#
# Chroot egress filter — restricts outbound network traffic from the chroot user
# on the remote host. This prevents data exfiltration via curl/wget/python3/etc.
# inside the chroot, even though those binaries are available to the agent.
#
# How it works:
#   - Uses iptables owner module to match packets from the chroot user's UID
#   - Allows: SSH return traffic (ESTABLISHED), DNS (port 53), loopback
#   - Optionally allows: HTTP/HTTPS to specific registries (npm, GitHub, PyPI)
#   - Drops everything else from the chroot user
#
# Usage:
#   chroot_egress_filter.sh <host-name>          # Apply filter
#   chroot_egress_filter.sh <host-name> --flush  # Remove filter
#
# Enable per-host by adding "chroot_egress_filter": true to config.json
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../../.env"
CONFIG_JSON="$SCRIPT_DIR/../../config.json"

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

# Load configuration
if [ ! -f "$ENV_FILE" ]; then
    log_error ".env file not found at $ENV_FILE"
    exit 1
fi
source "$ENV_FILE"

if [ -z "${1:-}" ]; then
    echo "Usage: $0 <host-name> [--flush]"
    exit 1
fi
HOST_NAME="$1"
FLUSH="${2:-}"

# Determine the UID of the agent user
if ! id "$AGENT_USER" &>/dev/null; then
    log_error "User $AGENT_USER does not exist"
    exit 1
fi
AGENT_UID=$(id -u "$AGENT_USER")

# iptables chain name for this filter
CHAIN="AGENT-CHROOT-EGRESS"

if [ "$FLUSH" = "--flush" ]; then
    echo "=== Removing chroot egress filter for $AGENT_USER (UID $AGENT_UID) ==="
    # Delete rules that jump to our chain
    iptables -D OUTPUT -j "$CHAIN" 2>/dev/null || true
    # Flush and delete the chain
    iptables -F "$CHAIN" 2>/dev/null || true
    iptables -X "$CHAIN" 2>/dev/null || true
    log_info "Chroot egress filter removed"
    exit 0
fi

echo "=== Applying chroot egress filter for $AGENT_USER (UID $AGENT_UID) ==="

# Create the chain if it doesn't exist
if ! iptables -L "$CHAIN" -n &>/dev/null; then
    iptables -N "$CHAIN"
fi

# Flush existing rules in the chain (re-apply on each run)
iptables -F "$CHAIN"

# ── Allow rules (order matters — first match wins) ──────────────────────────

# Allow loopback
iptables -A "$CHAIN" -o lo -j RETURN

# Allow established connections (SSH return traffic, etc.)
iptables -A "$CHAIN" -m owner --uid-owner "$AGENT_UID" -m state --state ESTABLISHED,RELATED -j RETURN

# Allow DNS (UDP and TCP) — needed for name resolution inside chroot
iptables -A "$CHAIN" -m owner --uid-owner "$AGENT_UID" -p udp --dport 53 -j RETURN
iptables -A "$CHAIN" -m owner --uid-owner "$AGENT_UID" -p tcp --dport 53 -j RETURN

# Allow SSH outbound (needed for the agent to SSH into this host from the container)
# Note: This allows the chroot user to SSH out. If this is not desired, remove this rule.
# The chroot already excludes SSH binaries, but the agent might use Python's paramiko.
# Uncomment the next line to allow SSH outbound from the chroot user:
# iptables -A "$CHAIN" -m owner --uid-owner "$AGENT_UID" -p tcp --dport 22 -j RETURN

# Allow HTTPS (port 443) to specific package registries
# This lets the agent install packages via npm/pip inside the chroot
# Comment out or remove these lines for maximum restriction
for domain in registry.npmjs.org pypi.org files.pythonhosted.org api.github.com github.com; do
    ips=$(dig +short A "$domain" 2>/dev/null || true)
    for ip in $ips; do
        if [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            iptables -A "$CHAIN" -m owner --uid-owner "$AGENT_UID" -d "$ip" -p tcp --dport 443 -j RETURN
            log_info "  Allowed HTTPS to $domain ($ip)"
        fi
    done
done

# ── Default: DROP all other outbound from the chroot user ───────────────────
iptables -A "$CHAIN" -m owner --uid-owner "$AGENT_UID" -j DROP

# ── Wire the chain into OUTPUT (only once) ─────────────────────────────────
if ! iptables -L OUTPUT -n | grep -q "$CHAIN"; then
    # Insert after lo ACCEPT rules, before any other rules
    iptables -I OUTPUT 2 -j "$CHAIN"
fi

echo ""
log_info "Chroot egress filter active for UID $AGENT_UID"
log_info "  Allowed: loopback, established, DNS (53), HTTPS to registries"
log_info "  Blocked: all other outbound from $AGENT_USER"
echo ""
log_info "To remove: $0 $HOST_NAME --flush"