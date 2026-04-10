# SSH Tunnels — Detailed Documentation

This guide explains the SSH tunnel architecture used by OpenClaw to access your local GPU machine.

## How It Works

1. SSH keys are generated on the **host** (not inside the container) using `scripts/ssh_key/init_keys.sh`
2. Keys are bind-mounted into the container at `/home/openclaw/.ssh/` (read-only)
3. The container's entrypoint generates SSH config from `config.json` and pre-seeds `known_hosts`
4. The `jail_set.sh` script creates a chroot jail on the target host and installs the public key
5. The container connects via SSH to execute commands on your project files
6. Project files are bind-mounted directly into the chroot user's home directory

## Configuration

All settings live in `.env` (project root):

| Variable | Description | Default |
|----------|-------------|---------|
| `AGENT_USER` | SSH user for the agent | `openclaw-bot` |
| `CHROOT_BASE` | Chroot jail path | `/srv/chroot/openclaw-bot` |
| `NGINX_HTTP_PORT` | HTTP port for dashboard | `8090` |

SSH hosts are defined in `config.json`:

```json
{
  "ssh_hosts": [
    {
      "name": "my-host",
      "hostname": "172.23.0.1",
      "user": "openclaw-bot",
      "strict_host_key_checking": true,
      "project_paths": ["/path/to/project1", "/path/to/project2"]
    }
  ]
}
```

## Setup Steps

### Prerequisites

- Docker and Docker Compose installed
- `sudo` access on the host
- SSH access to target machines

### Initial Setup

```bash
# 1. Initialize SSH keys on host
sudo bash scripts/ssh_key/init_keys.sh

# 2. Initialize dashboard auth
sudo bash scripts/nginx/init_htpasswd.sh

# 3. Start containers
docker compose up -d

# 4. Set up chroot jail on target host
sudo bash scripts/chroot_jail/jail_set.sh my-host
sudo systemctl reload sshd

# 5. Verify
docker exec -it openclaw ssh my-host whoami    # → openclaw-bot
docker exec -it openclaw ssh my-host ls        # → your project files
```

### After Container Restart

SSH keys are bind-mounted from `.ssh/` directory on the host, so they survive container restarts. However, if you regenerate keys or change the target host's authorized_keys, re-sync:

```bash
sudo bash scripts/ssh_key/add.sh my-host
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
├── usr/
│   ├── lib/    → bind mount (ro) from /usr/lib
│   ├── lib64/  → bind mount (ro) from /usr/lib64
│   └── bin/    → SYMLINKS to /usr/bin (SSH/network tools EXCLUDED)
├── dev/        → minimal device nodes (null, zero, pts)
├── proc/       → dedicated procfs (ro)
├── sys/        → dedicated sysfs (ro)
├── etc/        → passwd, group, nsswitch.conf, hosts, resolv.conf
└── home/
    └── openclaw-bot/  → project subdirectories (rw)
        ├── project1/
        └── project2/
```

### SSH/Network Binaries Excluded

The following binaries are **NOT** available inside the chroot (symlinks are not created):

- `ssh`, `scp`, `sftp` — Prevent jumping to other hosts
- `ssh-keygen`, `ssh-keyscan`, `ssh-agent`, `ssh-add` — Prevent key operations
- `nc`, `netcat`, `ncat`, `telnet`, `rsh`, `rlogin` — Prevent network tunneling

This is implemented via symlink exclusion in `jail_set.sh`:

```bash
EXCLUDE_BINARIES="ssh scp sftp ssh-keygen ssh-keyscan ssh-agent ssh-add nc netcat ncat telnet rsh rlogin"

for binary in /usr/bin/*; do
    binary_name=$(basename "$binary")
    # Skip excluded binaries
    for exclude in $EXCLUDE_BINARIES; do
        if [ "$binary_name" = "$exclude" ]; then
            continue 2  # Skip this binary
        fi
    done
    sudo ln -sf "$binary" "$CHROOT_BASE/usr/bin/$binary_name"
done
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
- **SSH binaries excluded** — agent cannot SSH to other hosts from within chroot

## Troubleshooting

### SSH falls back to password prompt

**Cause:** Key mismatch or missing `authorized_keys` on real filesystem.

```bash
sudo bash scripts/ssh_key/add.sh my-host
sudo systemctl reload sshd
```

### Permission denied (publickey, password)

**Cause:** Multiple possible issues. Run diagnostics:

Common fixes:
- Missing user in chroot's `/etc/passwd` → re-run `jail_set.sh`
- Missing `nsswitch.conf` in chroot → re-run `jail_set.sh`
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
docker exec openclaw ssh-keygen -lf /home/openclaw/.ssh/id_openclaw.pub
sudo ssh-keygen -lf /srv/chroot/openclaw-bot/home/openclaw-bot/.ssh/authorized_keys

# If different, re-sync
sudo bash scripts/ssh_key/add.sh my-host
sudo systemctl reload sshd
```

### Host key changed error

```bash
# Remove old host key
rm .ssh/known_hosts
# Restart container to re-seed known_hosts
docker compose restart openclaw
```

### SSH command not found in chroot

This is expected behavior — SSH binaries are intentionally excluded from the chroot for security. The agent cannot SSH to other hosts from within the chroot.

## Maintenance Scripts

| Script | Run as | Description |
|--------|--------|-------------|
| `scripts/ssh_key/init_keys.sh` | `sudo` | Generate SSH keys on host |
| `scripts/ssh_key/add.sh <host>` | `sudo` | Add public key to remote host's authorized_keys |
| `scripts/ssh_key/remove.sh <host>` | `sudo` | Remove public key from remote host |
| `scripts/chroot_jail/jail_set.sh <host>` | `sudo` | Full setup: chroot, user, keys, sshd config |
| `scripts/chroot_jail/jail_break.sh <host>` | `sudo` | Full teardown: unmount, remove user, clean sshd |
| `scripts/entrypoint.sh` | container | Auto-runs: SSH config generation, known_hosts pre-seed |
| `scripts/nginx/init_htpasswd.sh` | `sudo` | Generate .htpasswd for dashboard auth |
| `scripts/firewall/setup_firewall.sh` | `sudo` | Manage host firewall rules |
