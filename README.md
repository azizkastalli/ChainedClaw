# OpenClaw

AI agent platform with SSH bridge to your local GPU machine.

## Quick Start

### 1. Configure

Copy the example files and customize them with your settings:

```bash
cp .env.example .env
cp config.example.json config.json
```

Edit `.env` with your settings:

```bash
# Nginx ports
NGINX_HTTP_PORT=8090

# SSH chroot settings
AGENT_USER=openclaw-bot
CHROOT_BASE=/srv/chroot/openclaw-bot
```

Edit `config.json` with your SSH host details:

```json
{
  "ssh_hosts": [
    {
      "name": "my-host",
      "hostname": "172.23.0.1",
      "user": "openclaw-bot",
      "strict_host_key_checking": true,
      "project_paths": ["/path/to/your/project"]
    }
  ]
}
```

> **Tip:** When connecting from a Docker container to its host machine, use the Docker default gateway IP (typically `172.17.0.1` or check with `ip route | grep default` inside the container).

> **Note:** `.env` and `config.json` are excluded from git (see `.gitignore`) to keep your secrets safe. Never commit these files.

### 2. Initialize SSH Keys (on host)

```bash
bash scripts/ssh_key/init_keys.sh
```

This generates Ed25519 keys in `.ssh/` directory on the host.

### 3. Initialize Dashboard Auth (on host)

```bash
sudo bash scripts/nginx/init_htpasswd.sh
```

### 4. Start Services

```bash
docker compose up -d
```

This starts:
- **openclaw** — AI agent gateway (SSH keys mounted read-only from host)
- **openclaw-nginx** — Reverse proxy on port `$NGINX_HTTP_PORT`

### 5. Set Up Chroot on Target Hosts

The chroot setup script must run **on the target host itself** (not remotely from the OpenClaw host).

#### Local Host (Same Machine)

If the target host is the same machine running OpenClaw:

```bash
bash scripts/chroot_jail/jail_set.sh my-host
sudo systemctl reload sshd
```

#### Remote Host (Different Machine)

For remote machines, you need to:

1. **Get the SSH public key** from the OpenClaw host:
   ```bash
   # On OpenClaw host
   cat .ssh/id_openclaw.pub
   ```

2. **Copy scripts to the remote host**:
   ```bash
   # On OpenClaw host
   scp -r scripts/ user@remote-host:/tmp/openclaw-scripts/
   ```

3. **Run setup on the remote host**:
   ```bash
   # SSH to remote host
   ssh user@remote-host
   
   # On the remote host, run the setup
   cd /tmp/openclaw-scripts
   sudo bash scripts/chroot_jail/jail_set.sh my-host
   sudo systemctl reload sshd
   
   # Clean up
   rm -rf /tmp/openclaw-scripts
   ```

4. **Verify the connection** from OpenClaw host:
   ```bash
   docker exec -it openclaw ssh my-host whoami
   # Expected: openclaw-bot
   ```

> **Note:** The `hostname` in `config.json` should be the remote host's IP address or hostname that the OpenClaw container can reach.

### 6. Verify

```bash
docker exec -it openclaw ssh my-host whoami
# Expected: openclaw-bot

docker exec -it openclaw ssh my-host ls
# Expected: your project files
```

Open the dashboard at `http://localhost:8090`.

---

## SSH Tunnel Commands

| Command | Description |
|---------|-------------|
| `sudo bash scripts/ssh_key/init_keys.sh` | Generate SSH keys on host |
| `sudo bash scripts/chroot_jail/jail_set.sh <host>` | Set up chroot jail, user, SSH keys, sshd config |
| `sudo bash scripts/chroot_jail/jail_break.sh <host>` | Tear down everything (chroot, user, sshd config) |
| `sudo bash scripts/ssh_key/add.sh <host>` | Re-sync SSH key after container restart |
| `sudo systemctl reload sshd` | Apply sshd config changes |

> After any container recreate (`docker compose down && up`), re-sync the key:
> ```bash
> sudo bash scripts/ssh_key/add.sh my-host && sudo systemctl reload sshd
> ```

## Architecture

```
┌─────────────────────┐     SSH (ed25519)       ┌────────────────────────────────┐
│  OpenClaw Container │ ──────────────────────► │  Host Machine                  │
│  user: 1000:1000    │  user: openclaw-bot     │  Chroot: /srv/chroot/          │
│  read_only: true    │  StrictHostKey: yes     │    home/openclaw-bot/ ──►      │
│  cap_drop: ALL      │                         │    bind mount to PROJECT_PATH  │
└─────────────────────┘                         └────────────────────────────────┘
        │
        │ HTTP :8090 (localhost only)
        ▼
┌─────────────────────┐
│  Nginx Reverse Proxy│
│  Dashboard + API    │
│  Basic Auth enabled │
└─────────────────────┘
```

**Security features:**
- Ed25519 key authentication (no passwords)
- Host key pinned via `known_hosts` at startup
- Chroot jail isolates agent from host filesystem
- SSH binaries removed from chroot (cannot jump to other hosts)
- `/proc` and `/sys` mounted read-only
- TCP forwarding and tunneling disabled
- Container runs as non-root user (UID 1000)
- Read-only root filesystem with `cap_drop: ALL`
- SSH keys generated on host, mounted read-only into container

## File Structure

```
.env.example            # Example environment configuration (copy to .env)
config.example.json     # Example SSH host definitions (copy to config.json)
.env                    # Your local environment configuration (git-ignored)
config.json             # Your SSH host definitions (git-ignored)
docker-compose.yaml     # Container orchestration
nginx/
  nginx.conf            # Reverse proxy config
  html/index.html       # Static landing page
  .htpasswd             # Basic auth credentials (generated)
scripts/
  entrypoint.sh         # Container startup (SSH config generation, known_hosts)
  ssh_tunnels.md        # Detailed SSH tunnel documentation
  chroot_jail/
    jail_set.sh         # Host-side chroot + SSH setup
    jail_break.sh       # Host-side teardown
  firewall/
    setup_firewall.sh   # Host firewall management
  nginx/
    init_htpasswd.sh    # Generate .htpasswd for dashboard auth
  ssh_key/
    init_keys.sh        # Generate SSH keys on host
    add.sh              # Add public key to remote host
    remove.sh           # Remove public key from remote host
.ssh/                   # SSH keys (host-managed, git-ignored)
  id_openclaw           # Private key
  id_openclaw.pub       # Public key
  known_hosts           # Host keys
.openclaw-data/         # Agent state and data (bind mount)
```

## Troubleshooting

See [scripts/ssh_tunnels.md](scripts/ssh_tunnels.md) for detailed SSH tunnel documentation and troubleshooting.
