# OpenClaw

AI agent platform with SSH bridge to your local GPU machine.

## Quick Start

### 1. Configure

Edit `.env` with your settings:

```bash
# Nginx ports
NGINX_HTTP_PORT=8090
NGINX_HTTPS_PORT=8490

# SSH chroot settings
AGENT_USER=openclaw-bot
CHROOT_BASE=/srv/chroot/openclaw-bot
PROJECT_PATH=/home/aziz/Desktop/NEDO_RnD    # <-- your project directory
```

Edit `config.json` with your SSH host details:

```json
{
  "ssh_hosts": [
    {
      "name": "my-host",
      "hostname": "172.23.0.1",
      "user": "openclaw-bot",
      "strict_host_key_checking": true
    }
  ]
}
```

### 2. Start Services

```bash
docker compose up -d
```

This starts:
- **openclaw** — AI agent gateway (generates SSH keys on first run)
- **openclaw-nginx** — Reverse proxy on port `$NGINX_HTTP_PORT`

### 3. Set Up SSH Tunnel

The SSH tunnel lets the OpenClaw agent access your project files on the host machine through a secure chroot jail.

```bash
sudo bash scripts/setup_bot_ssh.sh
sudo systemctl reload sshd
```

### 4. Verify

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
| `sudo bash scripts/setup_bot_ssh.sh` | Set up chroot jail, user, SSH keys, sshd config |
| `sudo bash scripts/cleanup_bot_ssh.sh` | Tear down everything (chroot, user, sshd config) |
| `sudo bash scripts/add_key.sh` | Re-sync SSH key after container restart |
| `sudo systemctl reload sshd` | Apply sshd config changes |

> After any container recreate (`docker compose down && up`), re-sync the key:
> ```bash
> sudo bash scripts/add_key.sh && sudo systemctl reload sshd
> ```

## Architecture

```
┌─────────────────────┐     SSH (ed25519)      ┌────────────────────────────────┐
│  OpenClaw Container │ ──────────────────────► │  Host Machine                  │
│  key: id_openclaw   │  user: openclaw-bot     │  Chroot: /srv/chroot/          │
│  known_hosts pinned │  StrictHostKey: yes     │    home/openclaw-bot/ ──►      │
└─────────────────────┘                         │    bind mount to PROJECT_PATH  │
        │                                       └────────────────────────────────┘
        │ HTTP :8090
        ▼
┌─────────────────────┐
│  Nginx Reverse Proxy│
│  Dashboard + API    │
└─────────────────────┘
```

**Security features:**
- Ed25519 key authentication (no passwords)
- Host key pinned via `known_hosts` at startup
- Chroot jail isolates agent from host filesystem
- `/proc` and `/sys` mounted read-only
- TCP forwarding and tunneling disabled
- SSH keys persist in Docker volume `openclaw-sshkeys`

## File Structure

```
.env                    # All configuration (single source of truth)
config.json             # SSH host definitions
docker-compose.yaml     # Container orchestration
nginx/
  nginx.conf            # Reverse proxy config
  html/index.html       # Static landing page
scripts/
  entrypoint.sh         # Container startup (key gen, SSH config)
  setup_bot_ssh.sh      # Host-side chroot + SSH setup
  cleanup_bot_ssh.sh    # Host-side teardown
  add_key.sh            # Re-sync SSH key to host
  ssh_tunnels.md        # Detailed SSH tunnel documentation
```

## Troubleshooting

See [scripts/ssh_tunnels.md](scripts/ssh_tunnels.md) for detailed SSH tunnel documentation and troubleshooting.
