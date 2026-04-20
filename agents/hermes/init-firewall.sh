#!/bin/bash
# Internal firewall for agent containers (openclaw / claudecode)
# Restricts outbound connections to only necessary services:
#   npm registry, GitHub, Anthropic API, Sentry, Statsig
# SSH outbound is also allowed (needed for chroot host access).
# This runs inside the container's own network namespace (isolated by cap_drop:ALL + seccomp).
#
# Source: https://github.com/anthropics/claude-code/tree/main/.devcontainer
set -euo pipefail
IFS=$'\n\t'

# 1. Extract Docker DNS info BEFORE any flushing
DOCKER_DNS_RULES=$(iptables-save -t nat | grep "127\.0\.0\.11" || true)

# Flush existing rules and delete existing ipsets
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X
ipset destroy allowed-domains 2>/dev/null || true

# 2. Selectively restore ONLY internal Docker DNS resolution
if [ -n "$DOCKER_DNS_RULES" ]; then
    echo "Restoring Docker DNS rules..."
    iptables -t nat -N DOCKER_OUTPUT 2>/dev/null || true
    iptables -t nat -N DOCKER_POSTROUTING 2>/dev/null || true
    echo "$DOCKER_DNS_RULES" | xargs -L 1 iptables -t nat
else
    echo "No Docker DNS rules to restore"
fi

# Allow all traffic to/from Docker's internal DNS resolver (127.0.0.11).
# Port restriction intentionally omitted: Docker's NAT rewrites port 53 to a dynamic
# high port before the filter table sees the packet, so --dport 53 never matches.
# Matching on address alone is correct — 127.0.0.11 is only reachable within
# this container's network namespace (not a real host, not the internet).
iptables -A OUTPUT -d 127.0.0.11 -j ACCEPT
iptables -A INPUT  -s 127.0.0.11 -j ACCEPT

# Allow Docker's embedded DNS resolver to reach upstream DNS servers.
# Docker's 127.0.0.11 resolver forwards queries to external DNS (e.g., 8.8.8.8, 1.1.1.1).
# Without this, DNS resolution fails for external domains.
# We allow UDP and TCP on port 53 to any destination.
# DNS exfiltration risk: An attacker could encode data in DNS queries to arbitrary servers.
# Mitigation: This is acceptable because (a) the container is already restricted by iptables
# for all other outbound traffic, and (b) the data exfiltration value via DNS is limited.
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT
iptables -A INPUT  -p udp --sport 53 -j ACCEPT
iptables -A INPUT  -p tcp --sport 53 -j ACCEPT
# Allow SSH outbound to each host on its configured port (read from config.json).
# Fallback to port 22 if config is unavailable.
if [ -f /config.json ]; then
    while IFS=$'\t' read -r _ssh_ip _ssh_port; do
        [ -z "$_ssh_ip" ] && continue
        iptables -A OUTPUT -p tcp -d "$_ssh_ip" --dport "$_ssh_port" -j ACCEPT
        echo "Allowed SSH egress: $_ssh_ip:$_ssh_port"
    done < <(python3 -c "
import json
with open('/config.json') as f:
    c = json.load(f)
for h in c.get('ssh_hosts', []):
    print(h.get('hostname', '') + '\t' + str(h.get('port', 22)))
" 2>/dev/null)
else
    iptables -A OUTPUT -p tcp --dport 22 -j ACCEPT
fi
iptables -A INPUT  -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# Create ipset with CIDR support
ipset create allowed-domains hash:net

# Fetch and add GitHub IP ranges
echo "Fetching GitHub IP ranges..."
gh_ranges=$(curl -s https://api.github.com/meta)
if [ -z "$gh_ranges" ]; then
    echo "ERROR: Failed to fetch GitHub IP ranges"
    exit 1
fi
if ! echo "$gh_ranges" | jq -e '.web and .api and .git' >/dev/null; then
    echo "ERROR: GitHub API response missing required fields"
    exit 1
fi
echo "Processing GitHub IPs..."
while read -r cidr; do
    if [[ ! "$cidr" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        echo "ERROR: Invalid CIDR range from GitHub meta: $cidr"
        exit 1
    fi
    echo "Adding GitHub range $cidr"
    ipset add allowed-domains "$cidr"
done < <(echo "$gh_ranges" | jq -r '(.web + .api + .git)[]' | aggregate -q)

# resolve_domain DOMAIN — resolves A records and adds IPs to the allowed-domains ipset.
# Non-fatal: warns and skips on failure (used for optional/extra domains).
resolve_domain() {
    local domain="$1" strict="${2:-false}"
    echo "Resolving $domain..."
    local ips
    ips=$(dig +noall +answer A "$domain" | awk '$4 == "A" {print $5}')
    if [ -z "$ips" ]; then
        if [ "$strict" = "true" ]; then
            echo "ERROR: Failed to resolve $domain"
            exit 1
        else
            echo "WARN: Could not resolve $domain — skipping"
            return 0
        fi
    fi
    while read -r ip; do
        if [[ ! "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            echo "WARN: Unexpected DNS response for $domain: $ip — skipping"
            continue
        fi
        echo "  Adding $ip ($domain)"
        ipset add allowed-domains "$ip" 2>/dev/null || true
    done <<< "$ips"
}

# Core allowed domains (strict — container won't start if these can't be resolved)
for domain in \
    "registry.npmjs.org" \
    "api.anthropic.com" \
    "sentry.io" \
    "statsig.anthropic.com" \
    "statsig.com"; do
    resolve_domain "$domain" true
done

# Extra domains from EXTRA_ALLOWED_DOMAINS env var (space-separated, non-fatal)
# Set in docker-compose.yaml environment or .env:
#   EXTRA_ALLOWED_DOMAINS="api.openai.com my-litellm.example.com"
if [ -n "${EXTRA_ALLOWED_DOMAINS:-}" ]; then
    echo "Processing EXTRA_ALLOWED_DOMAINS..."
    for domain in $EXTRA_ALLOWED_DOMAINS; do
        resolve_domain "$domain" false
    done
fi

# Extra domains from config.json top-level allowed_domains array (non-fatal)
# Add to config.json: { "allowed_domains": ["api.openai.com", "my-litellm.host"] }
if [ -f /config.json ] && command -v python3 &>/dev/null; then
    while read -r domain; do
        [ -z "$domain" ] && continue
        resolve_domain "$domain" false
    done < <(python3 -c "
import json
with open('/config.json') as f:
    c = json.load(f)
for d in c.get('allowed_domains', []):
    print(d)
" 2>/dev/null)
fi

# Get host network from default route and allow it (needed for SSH to chroot hosts)
HOST_IP=$(ip route | grep default | cut -d" " -f3)
if [ -z "$HOST_IP" ]; then
    echo "ERROR: Failed to detect host IP"
    exit 1
fi
HOST_NETWORK=$(echo "$HOST_IP" | sed "s/\.[0-9]*$/.0\/24/")
echo "Host network detected as: $HOST_NETWORK"
iptables -A INPUT  -s "$HOST_NETWORK" -j ACCEPT
iptables -A OUTPUT -d "$HOST_NETWORK" -j ACCEPT

# Default DROP policy
iptables -P INPUT   DROP
iptables -P FORWARD DROP
iptables -P OUTPUT  DROP

# Allow established connections
iptables -A INPUT  -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Allow only whitelisted outbound destinations
iptables -A OUTPUT -m set --match-set allowed-domains dst -j ACCEPT

# Reject everything else with immediate feedback
iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited

echo "Firewall configuration complete"
echo "Verifying firewall rules..."
if curl --connect-timeout 5 https://example.com >/dev/null 2>&1; then
    echo "ERROR: Firewall verification failed - was able to reach https://example.com"
    exit 1
else
    echo "Firewall verification passed"
fi
if ! curl --connect-timeout 5 https://api.github.com/zen >/dev/null 2>&1; then
    echo "ERROR: Firewall verification failed - unable to reach https://api.github.com"
    exit 1
else
    echo "Firewall verification passed - GitHub API reachable"
fi
