# OpenClaw

AI agent platform with SSH bridge. The agent runs in a zero-trust container and
accesses your servers via hardened SSH chroot jails.

See [SECURITY.md](SECURITY.md) for the full security model and known limitations.

---

## Prerequisites

- Docker + Docker Compose
- [Sysbox](https://github.com/nestybox/sysbox) runtime (one-time host install — required for secure Docker-in-Docker)

```bash
# Ubuntu/Debian
VER=0.6.4
wget https://downloads.nestybox.com/sysbox/releases/v${VER}/sysbox-ce_${VER}-0.linux_amd64.deb
sudo apt-get install -y ./sysbox-ce_${VER}-0.linux_amd64.deb
```

---

## Quick Start

### 1. Configure

```bash
cp .env.example .env
cp config.example.json config.json
```

Edit `config.json` with your SSH hosts:

```json
{
  "ssh_hosts": [
    {
      "name": "my-server",
      "hostname": "192.168.1.100",
      "user": "openclaw-bot",
      "strict_host_key_checking": true,
      "isolation": "chroot",
      "project_paths": ["/path/to/project"],
      "forward_ports": []
    }
  ]
}
```

**`isolation` modes:**

| Mode | When to use |
|------|-------------|
| `chroot` | Bare-metal / VMs with sudo access |
| `restricted_key` | RunPod / containers where bind mounts aren't available |

**`forward_ports`** — allowlist ports the agent may tunnel to itself (e.g. `[3000, 8080]`).
Enforced by `PermitOpen` on the remote sshd. Empty = forwarding disabled. `chroot` mode only.

### 2. Initialize keys and dashboard auth

```bash
make keys    # generate Ed25519 keys in .ssh/
make auth    # create nginx .htpasswd
```

### 3. Pre-seed known_hosts (recommended for remote hosts)

Do this before `make up` to avoid a blind scan on first boot:

```bash
ssh-keyscan -H <remote-ip> >> .ssh/known_hosts
ssh-keyscan -H -p <port> <remote-ip> >> .ssh/known_hosts   # non-standard port
```

> Local host (`172.28.0.1`): the Docker bridge doesn't exist until `make up`, so a blind
> scan on first boot is acceptable — it's your own machine over a local bridge.

### 4. Start containers

```bash
make up
```

`make up` is mandatory-complete: it checks Sysbox, starts containers, and applies
the firewall in one step. All hosts must already be in `config.json` — the firewall
allowlists only those IPs.

### 5. Set up target hosts

```bash
make setup HOST=my-server       # chroot + SSH key + sshd reload in one step
make test HOST=my-server        # verify: should print "openclaw-bot"
```

**For remote hosts** (`chroot` mode):
```bash
make remote-setup HOST=my-server REMOTE_KEY=/path/to/key [REMOTE_USER=ubuntu]
```

**For remote hosts** (`restricted_key` mode — RunPod, containers):
```bash
make remote-setup HOST=my-runpod REMOTE_KEY=/path/to/key REMOTE_USER=root
```

After adding a new host to `config.json`, re-apply the firewall to pick up the new IP:
```bash
make firewall
```

### 6. Onboard OpenClaw

```bash
docker exec -it openclaw bash
openclaw onboard
```

Set the gateway port to `18789` and bind mode to `LAN`. Then copy the token from
`openclaw.json`, paste it in the dashboard at `http://localhost:8090`, and approve
the device:

```bash
openclaw devices list
openclaw devices approve <device-id>
```

### 7. Verify security layers

```bash
make preflight    # checks: Sysbox, firewall, container running
```

---

## Architecture

```
┌───────────────────────────────────────────────────────┐
│  openclaw host                                        │
│                                                       │
│  ┌───────────────────────────────────────────────┐    │
│  │  openclaw container  (sysbox-runc)            │    │
│  │  agent ──► inner Docker (user-namespaced)     │    │
│  │            └── browser / build containers     │    │
│  └───────────────────────────────────────────────┘    │
│       │ SSH ed25519                                   │
│       ▼                                               │
│  ┌─────────────────────────────────┐                  │
│  │  chroot jail (openclaw-bot)     │ ◄─ project_paths │
│  │  no SSH tools · /proc /sys ro   │                  │
│  └─────────────────────────────────┘                  │
│                                                       │
│  ┌──────────────────────┐                             │
│  │  nginx :8090 (local) │  basic auth dashboard       │
│  └──────────────────────┘                             │
└───────────────────────────────────────────────────────┘
```

---

## Command Reference

| Command | Description |
|---------|-------------|
| `make keys` | Generate SSH keys |
| `make auth` | Initialize dashboard auth |
| `make up` | Start containers + apply firewall |
| `make down` | Stop containers |
| `make restart` | Restart containers + re-apply firewall |
| `make preflight` | Verify all security layers |
| `make setup HOST=<h>` | Full host setup: chroot + key + sshd reload |
| `make test HOST=<h>` | Test SSH connection to host |
| `make firewall` | Re-apply firewall (after adding hosts) |
| `make firewall-flush` | Remove all firewall rules |
| `make remote-setup HOST=<h> REMOTE_KEY=<k>` | Set up chroot on a remote host |
| `make remote-clean HOST=<h> REMOTE_KEY=<k>` | Tear down chroot on a remote host |
| `make chroot HOST=<h>` | Chroot setup only (step 1 of setup) |
| `make key-add HOST=<h>` | Install SSH key only (step 2 of setup) |
| `make chroot-clean HOST=<h>` | Tear down chroot |
| `make sync HOST=<h>` | Re-sync SSH key (alias for key-add) |
| `make uninstall` | Full uninstallation |

---

## Troubleshooting

See [SSH_TUNNELS.md](SSH_TUNNELS.md).