#!/bin/bash
# Don't exit on errors - let the main app decide
set +e

# 1. Define paths
SSH_DIR="/root/.ssh"
KEY_FILE="$SSH_DIR/id_openclaw"
CONFIG_FILE="$SSH_DIR/config"
CONFIG_JSON="/config.json"

# 2. Create the .ssh directory if it doesn't exist
mkdir -p "$SSH_DIR"

# 3. Generate the SSH key ONLY if it doesn't already exist
if [ ! -f "$KEY_FILE" ]; then
    echo "Generating new SSH key for OpenClaw..."
    ssh-keygen -t ed25519 -f "$KEY_FILE" -N "" -C "openclaw-agent"
else
    echo "SSH key already exists. Skipping generation."
fi

# 4. Generate SSH config from config.json
echo "Creating SSH config file..."

# Generate SSH config using Python's built-in json module
python3 << 'PYTHON_EOF' > "$CONFIG_FILE"
import json
import os
import sys

CONFIG_JSON = os.environ.get('CONFIG_JSON', '/config.json')
KEY_FILE = os.environ.get('KEY_FILE', '/root/.ssh/id_openclaw')

try:
    with open(CONFIG_JSON, 'r') as f:
        config = json.load(f)
    
    print("# Auto-generated SSH config from config.json")
    
    if 'ssh_hosts' in config:
        for host in config['ssh_hosts']:
            name = host.get('name', 'unknown')
            hostname = host.get('hostname', '')
            user = host.get('user', 'root')
            strict_check = host.get('strict_host_key_checking', False)
            
            print(f"Host {name}")
            print(f"    HostName {hostname}")
            print(f"    User {user}")
            print(f"    IdentityFile {KEY_FILE}")
            print(f"    StrictHostKeyChecking {'yes' if strict_check else 'no'}")
            print("")
except FileNotFoundError:
    print(f"# Config file not found: {CONFIG_JSON}", file=sys.stderr)
    exit(1)
except Exception as e:
    print(f"# Error parsing config: {e}", file=sys.stderr)
    exit(1)
PYTHON_EOF

# 4b. Pre-seed known_hosts for configured hosts
echo "Pre-seeding known_hosts..."
KNOWN_HOSTS="$SSH_DIR/known_hosts"
python3 << 'PYTHON_EOF2'
import json, os, subprocess, sys

CONFIG_JSON = os.environ.get('CONFIG_JSON', '/config.json')
SSH_DIR = os.environ.get('SSH_DIR', '/root/.ssh')
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

chmod 644 "$KNOWN_HOSTS" 2>/dev/null || true

# 5. Apply the precise permissions you requested
echo "Setting strict permissions..."
chmod 700 "$SSH_DIR"
chmod 600 "$KEY_FILE"
chmod 644 "$KEY_FILE.pub"
chmod 600 "$CONFIG_FILE" 2>/dev/null || true

# 6. Hands off to the original OpenClaw start command
echo "SSH bridge ready. Starting OpenClaw..."
exec openclaw gateway run
