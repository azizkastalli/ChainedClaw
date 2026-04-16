#!/bin/bash
#
# Host-based firewall for OpenClaw container
# Blocks SSH access to any IP not in config.json
# Only affects OpenClaw container on internal network
#
# Security model: FORWARD chain (container egress filtering)
# - Allows established/related connections (return traffic)
# - Allows SSH only to IPs listed in config.json
# - Blocks all other outbound SSH from OpenClaw container
# - With --block-all: Blocks ALL non-SSH outbound traffic (stricter)
#
# IMPORTANT: This firewall ONLY affects the OpenClaw container.
# Other containers, host services, and SSH tunnels are NOT affected.
#

set -euo pipefail

# Define colors early (needed for log functions)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Parse arguments early (before loading .env for --flush/--help)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FLUSH_MODE=false
SHOW_HELP=false

for arg in "$@"; do
    case $arg in
        --flush)
            FLUSH_MODE=true
            ;;
        --help|-h)
            SHOW_HELP=true
            ;;
    esac
done

# Load configuration from .env (skip for --flush/--help)
# Use ENV_FILE from environment if set, otherwise use default path
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/../../.env}"
if [ "$FLUSH_MODE" = false ] && [ "$SHOW_HELP" = false ]; then
    if [ ! -f "$ENV_FILE" ]; then
        echo "ERROR: .env file not found at $ENV_FILE"
        exit 1
    fi
    source "$ENV_FILE"
fi

# Use unified variables with fallbacks
CONFIG_JSON="${CONFIG_JSON:-$SCRIPT_DIR/../../config.json}"
# NETWORK_NAME is available for future use (e.g., network-specific rules)
# shellcheck disable=SC2034
NETWORK_NAME="${AGENT_NETWORK_NAME:-agent-dev-net}"
CONTAINER_NAME="${AGENT_CONTAINER_NAME:-agent-dev}"
FIREWALL_MARKER="AGENT-DEV-FIREWALL"
WATCH_MODE=false
STRICT_MODE=false
BLOCK_ALL=false
PERSIST_MODE=true  # Default to persistent

# Expected static IP for validation (must match docker-compose.yaml)
EXPECTED_AGENT_IP="${EXPECTED_AGENT_IP:-172.28.0.10}"

# Check if running as root (skip for --help)
if [ "$SHOW_HELP" = false ]; then
    if [ "$EUID" -ne 0 ]; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi
fi

# Parse arguments
for arg in "$@"; do
    case $arg in
        --watch)
            WATCH_MODE=true
            ;;
        --strict)
            STRICT_MODE=true
            log_warn "Strict mode: Will block ALL outbound SSH from container"
            ;;
        --block-all)
            BLOCK_ALL=true
            log_warn "Block-all mode: Will block ALL non-SSH outbound traffic from container"
            ;;
        --no-persist)
            PERSIST_MODE=false
            ;;
        --flush)
            FLUSH_MODE=true
            ;;
        --help|-h)
        echo "Usage: $0 [--watch] [--strict] [--block-all] [--no-persist] [--flush]"
        echo ""
        echo "Options:"
        echo "  --watch      Monitor config.json for changes and auto-reload firewall rules"
        echo "  --strict     Block all outbound SSH (no whitelist exceptions)"
        echo "  --block-all  Block ALL non-SSH outbound traffic (stricter - blocks HTTP/HTTPS/DNS)"
        echo "  --no-persist Do NOT save rules across reboots (default is to persist)"
        echo "  --flush      Remove all agent-dev firewall rules"
        echo "  --help       Show this help message"
        echo ""
        echo "Note: Rules are persisted by default. Use --no-persist for ephemeral rules."
            exit 0
            ;;
    esac
done

# Install inotify-tools if not present (for --watch mode)
install_inotify_tools() {
    if ! command -v inotifywait &> /dev/null; then
        log_info "Installing inotify-tools..."
        if apt-get update -qq && apt-get install -y -qq inotify-tools; then
            log_info "inotify-tools installed successfully"
        else
            log_error "Failed to install inotify-tools"
            exit 1
        fi
    fi
}

# Install and configure iptables-persistent for rule persistence across reboots
install_persistence() {
    log_info "Setting up firewall persistence across reboots..."

    if ! dpkg -l iptables-persistent &>/dev/null 2>&1; then
        log_info "Installing iptables-persistent..."
        # Pre-answer debconf prompts to avoid interactive prompts
        echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | debconf-set-selections
        echo "iptables-persistent iptables-persistent/autosave_v6 boolean false" | debconf-set-selections
        if ! DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iptables-persistent > /dev/null 2>&1; then
            log_warn "Could not install iptables-persistent. Trying netfilter-persistent..."
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq netfilter-persistent > /dev/null 2>&1
        fi
    fi

    # Save current rules
    if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save
        log_info "Rules saved via netfilter-persistent (will survive reboots)"
    elif command -v iptables-save &>/dev/null; then
        mkdir -p /etc/iptables
        iptables-save > /etc/iptables/rules.v4
        log_info "Rules saved to /etc/iptables/rules.v4"

        # Create restore service if not present
        if [ ! -f /etc/systemd/system/agent-dev-firewall-restore.service ]; then
            cat > /etc/systemd/system/agent-dev-firewall-restore.service << 'EOF'
[Unit]
Description=Restore agent-dev iptables firewall rules
After=network.target docker.service
Wants=docker.service

[Service]
Type=oneshot
ExecStart=/sbin/iptables-restore /etc/iptables/rules.v4
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
            systemctl daemon-reload
            systemctl enable agent-dev-firewall-restore.service
            log_info "Created systemd service for rule restoration on boot"
        fi
    else
        log_warn "Could not persist rules. Install iptables-persistent manually:"
        log_warn "   apt install iptables-persistent &&  netfilter-persistent save"
    fi
}

# Check if config.json exists and required tools available
check_config() {
    if [ ! -f "$CONFIG_JSON" ]; then
        log_error "config.json not found at $CONFIG_JSON"
        exit 1
    fi

    if ! command -v jq &> /dev/null; then
        log_error "jq is required but not installed. Install with:  apt install jq"
        exit 1
    fi

    if ! command -v docker &> /dev/null; then
        log_error "docker is required but not installed"
        exit 1
    fi
}

# Get container IP on the network
# Tries docker inspect first; falls back to EXPECTED_AGENT_IP when running under
# sudo with a rootless Docker socket (inspect returns empty because root and the
# unprivileged user see different sockets).
get_container_ip() {
    local ip
    ip=$(docker inspect \
        --format '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' \
        "$CONTAINER_NAME" 2>/dev/null | tr ' ' '\n' | grep -v '^$' | head -1)

    if [ -z "$ip" ] && [ -n "${EXPECTED_AGENT_IP:-}" ]; then
        echo -e "${YELLOW}[WARN]${NC} docker inspect returned empty (rootless Docker / sudo socket mismatch)." >&2
        echo -e "${YELLOW}[WARN]${NC} Falling back to static IP from .env: $EXPECTED_AGENT_IP" >&2
        ip="$EXPECTED_AGENT_IP"
    fi

    echo "$ip"
}

# Validate container IP matches expected static IP
validate_container_ip() {
    if [ "$AGENT_IP" != "$EXPECTED_AGENT_IP" ]; then
        log_error "=========================================="
        log_error "CONTAINER IP MISMATCH DETECTED!"
        log_error "=========================================="
        log_error "  Expected: $EXPECTED_AGENT_IP"
        log_error "  Actual:   $AGENT_IP"
        log_error ""
        log_error "This usually means:"
        log_error "  1. Container was not started with static IP"
        log_error "  2. docker-compose.yaml IP configuration changed"
        log_error "  3. Container is on a different network"
        log_error ""
        log_error "Check docker-compose.yaml has:"
        log_error "  networks:"
        log_error "    agent-dev-net:"
        log_error "      ipv4_address: $EXPECTED_AGENT_IP"
        log_error ""
        log_error "Then restart: docker compose down && docker compose up -d"
        log_error "=========================================="
        exit 1
    fi
    log_info "Container IP validated: $AGENT_IP (matches expected static IP)"
}

# Remove all existing AGENT-DEV-FIREWALL rules from FORWARD chain
flush_openclaw_rules() {
    log_info "Flushing existing OpenClaw firewall rules..."
    # Loop until no more marked rules exist
    while iptables -L FORWARD -n --line-numbers 2>/dev/null | grep -q "$FIREWALL_MARKER"; do
        local line
        line=$(iptables -L FORWARD -n --line-numbers 2>/dev/null | grep "$FIREWALL_MARKER" | head -1 | cut -d' ' -f1)
        if [ -n "$line" ]; then
            iptables -D FORWARD "$line" 2>/dev/null || break
        else
            break
        fi
    done
}

# Resolve a hostname or IP string to a validated IPv4 address.
# Prints the resolved IP on success; prints nothing and returns 1 on failure.
resolve_to_ip() {
    local target="$1"
    local ip
    # Already an IPv4 address?
    if [[ "$target" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        # Validate each octet is 0-255
        local IFS=.
        read -ra octets <<< "$target"
        for octet in "${octets[@]}"; do
            if (( octet > 255 )); then
                log_warn "  Invalid IP address (octet out of range): $target"
                return 1
            fi
        done
        echo "$target"
        return 0
    fi
    # Try to resolve hostname
    ip=$(getent hosts "$target" 2>/dev/null | head -1 | cut -d' ' -f1)
    if [ -z "$ip" ]; then
        log_warn "  Cannot resolve hostname to IP: $target (skipping)"
        return 1
    fi
    log_info "  Resolved $target -> $ip"
    echo "$ip"
}

# Apply firewall rules
apply_firewall_rules() {
    log_info "Reading allowed SSH hosts from config.json..."
    # Read hostname:port pairs — use the configured port, not always 22
    mapfile -t RAW_ENTRIES < <(jq -r '.ssh_hosts[] | "\(.hostname):\(.port // 22)"' "$CONFIG_JSON" 2>/dev/null)

    if [ ${#RAW_ENTRIES[@]} -eq 0 ]; then
        log_error "No SSH hosts found in config.json"
        return 1
    fi

    # Resolve all hostnames/IPs and validate before touching iptables
    # ALLOWED_ENTRIES holds "ip:port" strings
    ALLOWED_ENTRIES=()
    ALLOWED_IPS=()  # kept for the summary log
    for entry in "${RAW_ENTRIES[@]}"; do
        [ -z "$entry" ] && continue
        raw_host="${entry%:*}"
        raw_port="${entry##*:}"
        resolved=$(resolve_to_ip "$raw_host") || continue
        ALLOWED_ENTRIES+=("$resolved:$raw_port")
        ALLOWED_IPS+=("$resolved")
    done

    if [ ${#ALLOWED_ENTRIES[@]} -eq 0 ]; then
        log_error "No valid IPs could be resolved from config.json ssh_hosts"
        return 1
    fi

    log_info "Allowed destination IPs: ${ALLOWED_IPS[*]}"

    # Get OpenClaw container IP
    log_info "Getting OpenClaw container IP..."
    AGENT_IP=$(get_container_ip)

    if [ -z "$AGENT_IP" ]; then
        log_error "Container '$CONTAINER_NAME' not found or not running"
        log_error "Start the container first: docker compose up -d"
        return 1
    fi

    log_info "Container IP: $AGENT_IP"

    # Validate IP matches expected static IP
    validate_container_ip

    # Remove existing rules for a clean slate
    flush_openclaw_rules

    log_info "Installing new firewall rules for $AGENT_IP ..."

    # Block-all mode: block ALL non-SSH outbound traffic from container
    if [ "$BLOCK_ALL" = true ]; then
        log_info "BLOCK-ALL mode: Blocking all non-SSH outbound traffic..."

        # 1. Allow established/related connections (return traffic) - MUST be first
        iptables -I FORWARD 1 \
            -s "$AGENT_IP" \
            -m conntrack --ctstate ESTABLISHED,RELATED \
            -m comment --comment "$FIREWALL_MARKER" \
            -j ACCEPT

        # 2. Allow SSH only to whitelisted IPs/ports
        for entry in "${ALLOWED_ENTRIES[@]}"; do
            [ -z "$entry" ] && continue
            ALLOWED_IP="${entry%:*}"
            ALLOWED_PORT="${entry##*:}"
            iptables -A FORWARD \
                -s "$AGENT_IP" -d "$ALLOWED_IP" \
                -p tcp --dport "$ALLOWED_PORT" \
                -m comment --comment "$FIREWALL_MARKER" \
                -j ACCEPT
            log_info "  BLOCK-ALL: Allowed SSH: $AGENT_IP -> $ALLOWED_IP:$ALLOWED_PORT"
        done

        # 3. Block all other outbound traffic (default deny)
        iptables -A FORWARD \
            -s "$AGENT_IP" \
            -m comment --comment "$FIREWALL_MARKER" \
            -j DROP
        log_info "  BLOCK-ALL: Blocked all other outbound traffic from $AGENT_IP"

    elif [ "$STRICT_MODE" = true ]; then
        # Strict mode: block ALL outbound SSH from container
        # 1. Allow established/related connections (return traffic)
        iptables -I FORWARD 1 \
            -s "$AGENT_IP" \
            -m conntrack --ctstate ESTABLISHED,RELATED \
            -m comment --comment "$FIREWALL_MARKER" \
            -j ACCEPT

        # 2. Allow SSH only to whitelisted IPs/ports
        for entry in "${ALLOWED_ENTRIES[@]}"; do
            [ -z "$entry" ] && continue
            ALLOWED_IP="${entry%:*}"
            ALLOWED_PORT="${entry##*:}"
            iptables -A FORWARD \
                -s "$AGENT_IP" -d "$ALLOWED_IP" \
                -p tcp --dport "$ALLOWED_PORT" \
                -m comment --comment "$FIREWALL_MARKER" \
                -j ACCEPT
            log_info "  STRICT: Allowed SSH: $AGENT_IP -> $ALLOWED_IP:$ALLOWED_PORT"
        done

        # 3. Block all other outbound SSH (default deny)
        iptables -A FORWARD \
            -s "$AGENT_IP" \
            -p tcp --dport 22 \
            -m comment --comment "$FIREWALL_MARKER" \
            -j DROP
        log_info "  STRICT: Blocked all other outbound SSH from $AGENT_IP"

    else
        # Default mode: Allow SSH to whitelisted IPs only
        # 1. Allow established/related connections (return traffic)
        iptables -I FORWARD 1 \
            -s "$AGENT_IP" \
            -m conntrack --ctstate ESTABLISHED,RELATED \
            -m comment --comment "$FIREWALL_MARKER" \
            -j ACCEPT

        # 2. Allow SSH only to whitelisted IPs/ports
        for entry in "${ALLOWED_ENTRIES[@]}"; do
            [ -z "$entry" ] && continue
            ALLOWED_IP="${entry%:*}"
            ALLOWED_PORT="${entry##*:}"
            iptables -A FORWARD \
                -s "$AGENT_IP" -d "$ALLOWED_IP" \
                -p tcp --dport "$ALLOWED_PORT" \
                -m comment --comment "$FIREWALL_MARKER" \
                -j ACCEPT
            log_info "  DEFAULT: Allowed SSH: $AGENT_IP -> $ALLOWED_IP:$ALLOWED_PORT"
        done

        # 3. Block all other outbound SSH (default deny)
        iptables -A FORWARD \
            -s "$AGENT_IP" \
            -p tcp --dport 22 \
            -m comment --comment "$FIREWALL_MARKER" \
            -j DROP
        log_info "  DEFAULT: Blocked all other outbound SSH from $AGENT_IP"
    fi
}

# Watch mode: monitor config.json for changes and re-apply rules
run_watch_mode() {
    log_info "Starting watch mode - monitoring $CONFIG_JSON for changes..."

    # Initial apply
    apply_firewall_rules

    # Watch for changes
    while inotifywait -q -e modify,move,create "$CONFIG_JSON" 2>/dev/null; do
        log_info "Detected change in config.json, reloading firewall rules..."
        if apply_firewall_rules; then
            log_info "Rules reloaded successfully."
        else
            log_error "Rule reload FAILED — previous rules may still be active."
        fi
    done
}

# Show forward_ports per host from config.json (informational — enforced by PermitOpen on remote sshd)
show_forward_ports() {
    if [ ! -f "$CONFIG_JSON" ] || ! command -v jq &>/dev/null; then
        return
    fi
    local any_ports=false
    while IFS= read -r line; do
        local name ports
        name=$(echo "$line" | jq -r '.name')
        ports=$(echo "$line" | jq -r '.forward_ports // [] | map(tostring) | join(", ")')
        if [ -n "$ports" ]; then
            log_info "  $name → forward_ports: $ports  (enforced via PermitOpen in remote sshd)"
            any_ports=true
        fi
    done < <(jq -c '.ssh_hosts[]' "$CONFIG_JSON" 2>/dev/null)
    if [ "$any_ports" = false ]; then
        echo "  (no forward_ports configured — AllowTcpForwarding no on all hosts)"
    fi
}

# Show current firewall status
show_status() {
    log_info "Current AGENT-DEV-FIREWALL rules:"
    echo ""
    iptables -L FORWARD -n --line-numbers -v | grep "$FIREWALL_MARKER" || echo "  (no rules found)"
    echo ""
    log_info "Active allowed SSH destinations:"
    iptables -L FORWARD -n | grep "$FIREWALL_MARKER" | grep ACCEPT | \
        while read -r _ _ _ _ _ _ _ _ _ dst _ dpt _; do echo "$dst -> port $dpt"; done | sort -u || echo "  (none)"
    echo ""
    log_info "Allowed port forwards per host (enforced by PermitOpen on remote sshd, not iptables):"
    show_forward_ports
}

# Main script body

# Handle help mode early
if [ "$SHOW_HELP" = true ]; then
    echo "Usage: $0 [--watch] [--strict] [--block-all] [--no-persist] [--flush]"
    echo ""
    echo "Options:"
    echo "  --watch      Monitor config.json for changes and auto-reload firewall rules"
    echo "  --strict     Block all outbound SSH (no whitelist exceptions)"
    echo "  --block-all  Block ALL non-SSH outbound traffic (stricter - blocks HTTP/HTTPS/DNS)"
    echo "  --no-persist Do NOT save rules across reboots (default is to persist)"
    echo "  --flush      Remove all agent-dev firewall rules"
    echo "  --help       Show this help message"
    echo ""
    echo "Note: Rules are persisted by default. Use --no-persist for ephemeral rules."
    exit 0
fi

# Handle flush mode (doesn't require config.json)
if [ "$FLUSH_MODE" = true ]; then
    # Check if running as root for flush
    if [ "$EUID" -ne 0 ]; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi
    flush_openclaw_rules
    echo ""
    log_info "All agent-dev firewall rules have been removed."
    echo ""
    show_status
    exit 0
fi

check_config

if [ "$WATCH_MODE" = true ]; then
    install_inotify_tools
    run_watch_mode
else
    apply_firewall_rules

    if [ "$PERSIST_MODE" = true ]; then
        install_persistence
    fi

    echo ""
    log_info "Done! Agent container ($AGENT_IP) can only SSH to:"
    for IP in "${ALLOWED_IPS[@]}"; do
        log_info "  - $IP"
    done
    echo ""
    log_info "Other containers and host traffic are NOT affected."

    if [ "$PERSIST_MODE" = false ]; then
        log_warn "Rules are NOT persistent (lost on reboot)."
        log_warn "Rules will need to be re-applied after restart."
    else
        log_info "Rules are persisted and will survive reboots."
    fi

    echo ""
    show_status

    echo ""
    log_info "To auto-reload on config.json changes:"
    log_info "   bash scripts/firewall/setup_firewall.sh --watch"
fi
