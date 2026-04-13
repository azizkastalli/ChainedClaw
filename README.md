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
      "isolation": "chroot",
      "project_paths": ["/path/to/your/project"]
    }
  ]
}
```

#### Isolation modes

Each host has an `isolation` field that controls how the agent is sandboxed:

| Mode | When to use | How it works |
|------|-------------|--------------|
| `chroot` (default) | Bare-metal servers, VMs | Full chroot jail — strongest isolation |
| `restricted_key` | RunPod, Docker containers | SSH key restrictions only — no chroot needed |

Use `restricted_key` when the remote host is already an isolated Docker/RunPod container and bind mounts are not available (`CAP_SYS_ADMIN` not granted). The key is installed with `restrict,pty` which blocks port forwarding, agent forwarding, and X11, while still allowing the agent to run commands.

> **Tip:** When connecting from a Docker container to its host machine, use the Docker default gateway IP (typically `172.17.0.1` or check with `ip route | grep default` inside the container).

> **Note:** `.env` and `config.json` are excluded from git (see `.gitignore`) to keep your secrets safe. Never commit these files.

### 2. Initialize SSH Keys (on host)

```bash
make keys
```

This generates Ed25519 keys in `.ssh/` directory on the host.

> **Note:** If the container is already running when you run `make keys`, restart it (`make down && make up`) so the entrypoint regenerates the SSH config with the new keys. Then run `make key-add HOST=<host>` for each configured host.

#### Pre-seed known_hosts (recommended for remote hosts)

On first boot the container runs `ssh-keyscan` to pin host keys. For **remote hosts** (RunPod, external servers) pre-seeding before starting the container eliminates the MITM risk of a blind scan:

```bash
# Standard port
ssh-keyscan -H <remote-ip> >> .ssh/known_hosts

# Non-standard port (e.g. RunPod)
ssh-keyscan -H -p <port> <remote-ip> >> .ssh/known_hosts
```

Do this before `make up`. If the container is already running, add the entry then restart:
```bash
make down && make up
```

> **Local host (`172.28.0.1`):** this IP is the Docker bridge gateway and only exists after `make up` creates the network — you cannot scan it beforehand. The blind scan on first boot is acceptable here since you are scanning your own machine over a local Docker bridge (not a public network). The key is cached after the first boot and subsequent starts skip the scan entirely.

### 3. Initialize Dashboard Auth (on host)

```bash
make auth
```

### 4. Start Services

```bash
make up
```

This starts:
- **openclaw** — AI agent gateway (SSH keys mounted read-only from host)
- **openclaw-nginx** — Reverse proxy on port `$NGINX_HTTP_PORT`

> **Important — order matters:** The remote host and localhost must be in `config.json` before any other step. Two things depend on it:
> - `jail_set.sh` reads `project_paths` from `config.json` and exits with an error if the host entry is missing.
> - The firewall whitelists only IPs listed in `config.json`. Without re-running `make firewall` after adding the host, the container's SSH connection to that IP will be dropped by the firewall even if the chroot is correctly set up.
> - Run the firewall only on the openclaw container host not the remote servers.

### 5. Set Up Firewall (on host)

```bash
make firewall
```

This installs persistent iptables rules that restrict the container's SSH egress to only the hosts listed in `config.json`. Rules survive reboots by default.

> **Stricter mode** (blocks all non-SSH outbound traffic too):
> ```bash
> sudo bash scripts/firewall/setup_firewall.sh --block-all
> ```


### 6. Set Up Target Hosts

The isolation mode in `config.json` controls what gets set up. Both modes are handled by the same `make` commands.

#### Local Host (Container Host Machine)

```bash
make chroot HOST=my-host    # sets up chroot jail OR creates user (restricted_key)
make key-add HOST=my-host   # installs key with correct restrictions for the mode
```

#### Test Local Setup (Container Host Machine)
```bash
make test HOST=my-host    # channge my-host by your config host name
```

#### Remote Host — `chroot` mode (bare metal / VM)

Use this for servers where you have full sudo access and bind mounts work.

Set `"isolation": "chroot"` in `config.json`, then:

1. **Add the host to `config.json`**:
   ```json
   {
     "name": "my-server",
     "hostname": "<remote-ip>",
     "user": "openclaw-bot",
     "strict_host_key_checking": true,
     "isolation": "chroot",
     "project_paths": ["/path/to/project"]
   }
   ```

2. **Pre-seed the host key** (avoids blind ssh-keyscan on container start):
   ```bash
   ssh-keyscan -H -p <remote-ssh-port> <remote-ip> >> .ssh/known_hosts
   ```

3. **Re-apply the firewall**:
   ```bash
   make firewall
   ```

4. **Run remote setup**:
   ```bash
   make remote-setup HOST=my-server REMOTE_KEY=/path/to/ssh/key [REMOTE_USER=ubuntu]
   ```
   This copies scripts, runs `jail_set.sh` (chroot), installs the key, and reloads sshd.

5. **Verify**:
   ```bash
   make test HOST=my-server
   ```

#### Setup OpenClaw
```bash
docker exec -it openclaw bash
openclaw onboard
# or openclaw config (for specific config edits)
```
 - For the gateway config set the port to `18789` and gateway bind Mode `LAN`
- After setting up the config and to access openclaw dashboard via localhost:8090, copy the generated token from openclaw.json file and past it in the dashboard token authentification field, next execute the following commands inside the openclaw container:
  ```bash
  openclaw devices list
  ```
* Get the device request id and execute the following command:
  ```bash
  openclaw devices approve <device-id>
  ```

#### Remote Host — `restricted_key` mode (RunPod / Docker containers)

Use this when the remote host is already an isolated Docker or RunPod container where bind mounts are not available (`CAP_SYS_ADMIN` not granted). No chroot is created — instead the SSH key is installed with `restrict,pty` which blocks port forwarding, agent forwarding, and X11.

Set `"isolation": "restricted_key"` in `config.json`, then:

1. **Add the host to `config.json`**:
   ```json
   {
     "name": "my-runpod",
     "hostname": "<pod-ip>",
     "port": 15775,
     "user": "openclaw-bot",
     "strict_host_key_checking": true,
     "isolation": "restricted_key",
     "project_paths": ["/workspace/my_project"]
   }
   ```

2. **Pre-seed the host key** (required for non-standard ports):
   ```bash
   ssh-keyscan -H -p 15775 <pod-ip> >> .ssh/known_hosts
   ```

3. **Re-apply the firewall**:
   ```bash
   make firewall
   ```

4. **Run remote setup**:
   ```bash
   make remote-setup HOST=my-runpod REMOTE_KEY=/path/to/ssh/key REMOTE_USER=root
   ```
   This creates the `openclaw-bot` user and installs the restricted key. No sshd reload is needed.

5. **Verify**:
   ```bash
   make test HOST=my-runpod
   ```

To remove a remote host setup:
```bash
make remote-clean HOST=my-host REMOTE_KEY=/path/to/ssh/key [REMOTE_USER=user]
```

### 7. Verify

```bash
make test HOST=my-host
# Expected output: openclaw-bot

docker exec -it openclaw ssh my-host ls
# Expected: your project files
```

Open the dashboard at `http://localhost:8090` (credentials from step 3).

---

## SSH Tunnel Commands

| Command | Description |
|---------|-------------|
| `make keys` | Generate SSH keys on host |
| `make auth` | Initialize dashboard credentials |
| `make up` / `make down` | Start / stop containers |
| `make firewall` | Install persistent egress firewall rules |
| `make firewall-flush` | Remove firewall rules |
| `make chroot HOST=<host>` | Set up chroot jail on local host |
| `make remote-setup HOST=<host> REMOTE_KEY=<key>` | Set up chroot on a remote host (hostname/port from config.json) |
| `make remote-clean HOST=<host> REMOTE_KEY=<key>` | Tear down chroot on a remote host |
| `make key-add HOST=<host>` | Install SSH key into chroot and reload sshd |
| `make chroot-clean HOST=<host>` | Tear down chroot, user, sshd config |
| `make sync HOST=<host>` | Re-sync SSH key (alias for `key-add`) |
| `make test HOST=<host>` | Test SSH connection |
| `make uninstall` | Full uninstallation |

> **After `make chroot-clean`**, the chroot and its authorized key are gone. To restore access:
> ```bash
> make chroot HOST=my-host
> make key-add HOST=my-host
> ```

> **After any container recreate** (`make down && make up`), install or re-sync the key:
> ```bash
> make key-add HOST=my-host   # first time, or after make keys regenerates keys
> make sync HOST=my-host      # alias — use either one
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
- Host key pinning via `known_hosts` (scanned on first boot only; skipped when pre-seeded or entries already present)
- Chroot jail isolates agent from host filesystem
- SSH binaries removed from chroot (cannot jump to other hosts)
- `/proc` and `/sys` mounted read-only
- TCP forwarding and tunneling disabled
- Container runs as non-root user (UID 1000)
- Read-only root filesystem with `cap_drop: ALL`
- SSH keys generated on host, mounted read-only into container
- Dashboard protected by Nginx basic auth (credentials via `init_htpasswd.sh`)
- Gateway binds only to its static container IP (`172.28.0.10`), not `0.0.0.0`

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
  remote/
    setup.sh            # Automated remote chroot setup (copies files + runs jail_set + add)
    teardown.sh         # Automated remote chroot teardown (runs jail_break + cleanup)
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
