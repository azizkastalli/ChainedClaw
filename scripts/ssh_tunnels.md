# SSH Tunnels — Detailed Documentation

This guide explains the SSH tunnel architecture used by OpenClaw to access your local GPU machine.

## How It Works

1. The OpenClaw container generates an Ed25519 SSH key pair at startup (`/root/.ssh/id_openclaw`)
2. The `setup_bot_ssh.sh` script creates a chroot jail on the host and installs the public key
3. The container connects via SSH to execute commands on your project files
4. Project files are bind-mounted directly into the chroot user's home directory

## Configuration

All settings live in `.env` (project root):

| Variable | Description | Default |
|----------|-------------|---------|
| `AGENT_USER` | SSH user for the agent | `openclaw-bot` |
| `CHROOT_BASE` | Chroot jail path | `/srv/chroot/openclaw-bot` |
| `PROJECT_PATH` | Host path to your project | `/home/aziz/Desktop/NEDO_RnD` |
| `NGINX_HTTP_PORT` | HTTP port for dashboard | `8090` |
| `NGINX_HTTPS_PORT` | HTTPS port for dashboard | `8490` |

SSH hosts are defined in `config.json`:

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

## Setup Steps

### Prerequisites

- Docker and Docker Compose installed
- `sudo` access on the host
- OpenClaw container running (`docker compose up -d`)

### Initial Setup

```bash
# 1. Start containers
docker compose up -d

# 2. Set up SSH bridge
sudo bash scripts/setup_bot_ssh.sh
sudo systemctl reload sshd

# 3. Verify
docker exec -it openclaw ssh my-host whoami    # → openclaw-bot
docker exec -it openclaw ssh my-host ls        # → your project files
```

### After Container Restart

SSH keys persist in the `openclaw-sshkeys` Docker volume, so they survive container restarts. However, if you run `docker compose down` and then `docker compose up -d`, the volume is preserved — just verify:

```bash
docker exec -it openclaw ssh my-host whoami
```

If it fails (container was recreated with a fresh volume), re-sync the key:

```bash
sudo bash scripts/add_key.sh
sudo systemctl reload sshd
```

## Security Architecture

### Chroot Jail

The agent is confined to `/srv/chroot/openclaw-bot/`. Inside the chroot:

```
/
├── bin/        → bind mount (ro) from /bin
├── lib/        → bind mount (ro) from /lib
├── lib64/      → bind mount (ro) from /lib64
├── usr/        → bind mount (ro) from /usr
├── dev/        → minimal device nodes (null, zero, pts)
├── proc/       → dedicated procfs (ro)
├── sys/        → dedicated sysfs (ro)
├── etc/        → passwd, group, nsswitch.conf, hosts, resolv.conf
└── home/
    └── openclaw-bot/  → bind mount (rw) from PROJECT_PATH
```

### sshd Configuration

Applied via `Match User` block in `/etc/ssh/sshd_config`:

```
Match User openclaw-bot
    ChrootDirectory /srv/chroot/openclaw-bot
    X11Forwarding no
    AllowTcpForwarding no
    PermitTunnel no
```

### Key Points

- **No password auth** — key-based only
- **Host key pinned** — `known_hosts` pre-seeded at container startup
- **`StrictHostKeyChecking yes`** — rejects MITM attacks
- **Read-only system mounts** — `/proc` and `/sys` are mounted as dedicated read-only filesystems (not bind mounts) to prevent read-only propagation to the host
- **No TCP forwarding** — prevents port-forward abuse
- **No tunneling** — prevents tunnel creation
- **Dual authorized_keys** — installed in both chroot and real filesystem (required by OpenSSH for ChrootDirectory users)

## Troubleshooting

### SSH falls back to password prompt

**Cause:** Key mismatch or missing `authorized_keys` on real filesystem.

```bash
sudo bash scripts/add_key.sh
sudo systemctl reload sshd
```

### Permission denied (publickey, password)

**Cause:** Multiple possible issues. Run diagnostics:

Common fixes:
- Missing user in chroot's `/etc/passwd` → re-run `setup_bot_ssh.sh`
- Missing `nsswitch.conf` in chroot → re-run `setup_bot_ssh.sh`
- Wrong permissions on `.ssh` → `sudo chmod 700`, `authorized_keys` → `sudo chmod 600`

### Docker won't start after setup

**Cause:** Read-only `/proc` propagation from bind mounts (fixed in current scripts using dedicated filesystems).

```bash
sudo mount -o remount,rw /proc
docker compose up -d
```

### Container key changed

```bash
# Check fingerprints
docker exec openclaw ssh-keygen -lf /root/.ssh/id_openclaw.pub
sudo ssh-keygen -lf /srv/chroot/openclaw-bot/home/openclaw-bot/.ssh/authorized_keys

# If different, re-sync
sudo bash scripts/add_key.sh
sudo systemctl reload sshd
```

### Host key changed error

```bash
docker exec openclaw rm /root/.ssh/known_hosts
docker compose restart openclaw
```

## Maintenance Scripts

| Script | Run as | Description |
|--------|--------|-------------|
| `scripts/setup_bot_ssh.sh` | `sudo` | Full setup: chroot, user, keys, sshd config |
| `scripts/cleanup_bot_ssh.sh` | `sudo` | Full teardown: unmount, remove user, clean sshd |
| `scripts/add_key.sh` | `sudo` | Re-sync SSH key from container to host |
| `scripts/entrypoint.sh` | container | Auto-runs: key gen, SSH config, known_hosts |
