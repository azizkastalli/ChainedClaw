# OpenClaw

AI agent platform with SSH bridge. The agent runs in a hardened, zero-trust container and accesses your servers via locked-down SSH chroot jails. Every security layer is designed around one assumption: **the agent container may be compromised at any time** (e.g. via prompt injection).

See [SECURITY.md](SECURITY.md) for the full threat model, layer-by-layer breakdown, and known limitations.

---

## How it works

```
┌────────────────────────────────────────────────────────────┐
│  Host machine                                              │
│                                                            │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  agent-dev container  (uid 1000, no capabilities)    │  │
│  │                                                      │  │
│  │  openclaw / claude process                           │  │
│  │    ↳ internal firewall (iptables)                    │  │
│  │      only npm, GitHub, Anthropic API reachable       │  │
│  └───────────────────┬──────────────────────────────────┘  │
│                      │ SSH ed25519 (key in ssh-agent)      │
│                      ▼                                     │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  chroot jail  (dev-bot user, project_paths only)     │  │
│  │    no SSH/network tools · /proc /sys read-only       │  │
│  │    PermitOpen enforces port-forward allowlist        │  │
│  └──────────────────────────────────────────────────────┘  │
│                                                            │
│  ┌──────────────────────────┐                              │
│  │  nginx :8090 (localhost) │  basic auth dashboard        │
│  └──────────────────────────┘                              │
│                                                            │
│  Host iptables FORWARD chain                               │
│    SSH egress from agent → config.json hosts only          │
└────────────────────────────────────────────────────────────┘
```

**Three container modes are available — only one runs at a time:**

| Mode | Command | What runs inside |
|------|---------|-----------------|
| `openclaw` | `make up AGENT=openclaw` | OpenClaw gateway + nginx dashboard |
| `claudecode` | `make up AGENT=claudecode` | Claude Code CLI (headless) |
| `hermes-agent` | `make up AGENT=hermes-agent` | Hermes Agent (NousResearch) interactive CLI |

All modes share the same container name, static IP, and firewall rules. Switching is a `make down` + `make up AGENT=<other>`.

---

## Prerequisites

- Docker + Docker Compose (v2)
- `sudo` access on the host (for iptables firewall rules and chroot setup)
- Docker must support seccomp (`docker info | grep seccomp`)

No other host dependencies required.

---

## Quick Start

### 1. Copy config files

```bash
cp .env.example .env
cp config.example.json config.json
```

Edit `.env` if you need to change the dashboard port or container names. The defaults work for most setups.

### 2. Configure your SSH hosts

Edit `config.json` to list every host the agent may SSH into:

```json
{
  "ssh_hosts": [
    {
      "name": "my-server",
      "hostname": "192.168.1.100",
      "port": 22,
      "user": "dev-bot",
      "strict_host_key_checking": true,
      "isolation": "chroot",
      "project_paths": ["/path/to/your/project"],
      "forward_ports": [],
      "chroot_egress_filter": false,
      "docker_access": false
    }
  ]
}
```

**All hosts must be listed before `make up`.** The FORWARD chain firewall locks SSH egress to exactly these IPs — the agent cannot reach any host not in this file.

**Field reference:**

| Field | Required | Description |
|-------|----------|-------------|
| `name` | Yes | Short alias used by SSH config and make targets |
| `hostname` | Yes | IP or hostname of the target server |
| `port` | No (default: 22) | SSH port |
| `user` | No (default: root) | SSH user inside the chroot |
| `strict_host_key_checking` | No (default: true) | Set to `false` only for ephemeral hosts |
| `isolation` | Yes | `chroot` or `restricted_key` — see below |
| `project_paths` | Yes | Directories the agent can access inside the chroot |
| `forward_ports` | No | Ports the agent may tunnel to itself (e.g. `[3000, 8080]`) |
| `chroot_egress_filter` | No (default: false) | Lock outbound traffic from the chroot user to known registries only |
| `docker_access` | No (default: false) | Give the chroot user access to a rootless Docker daemon |

**Isolation modes:**

| Mode | When to use |
|------|-------------|
| `chroot` | Standard VMs and bare-metal servers where you have sudo access |
| `restricted_key` | Managed environments (RunPod, shared containers) where bind mounts and sudo are unavailable |

**`forward_ports`** — ports the agent may tunnel back to itself (e.g. to reach a dev server from nginx). Enforced by `PermitOpen` in sshd — the remote SSH server rejects any port-forward request not on this list. Empty array disables forwarding entirely. `chroot` mode only.

**`chroot_egress_filter`** — when enabled, iptables rules on the remote host restrict outbound traffic from the chroot user to DNS + HTTPS to package registries (npm, PyPI, GitHub) only. Closes the main remaining attack path: without this, `curl`/`wget` inside the chroot can reach arbitrary internet endpoints.

**`docker_access`** — when enabled, a rootless Docker daemon is set up for the chroot user. Containers run in a user namespace — they cannot escape to the host Docker daemon or run `--privileged`. Without this, the `docker` binary is excluded from the chroot entirely.

### 3. Generate SSH keys and dashboard credentials

```bash
make keys    # generates Ed25519 keys in .ssh/
make auth    # creates nginx .htpasswd (prints credentials)
```

`make keys` creates:
- `.ssh/id_agent` — private key (mode 640, loaded into ssh-agent at container start)
- `.ssh/id_agent.pub` — public key (installed on remote hosts)
- `.ssh/known_hosts` — pre-seeded with host fingerprints on first run
- `.openclaw-data/`, `.claudecode-data/`, and `.hermes-data/` — persistent agent data directories

Save the `make auth` output — the dashboard password is not stored in plaintext anywhere. To regenerate it run `make auth` again.

### 4. Pre-seed known_hosts (strongly recommended)

Do this before `make up` to avoid a blind `ssh-keyscan` on first boot (MITM window):

```bash
ssh-keyscan -H <remote-ip> >> .ssh/known_hosts
ssh-keyscan -H -p <port> <remote-ip> >> .ssh/known_hosts   # non-standard port
```

If `.ssh/known_hosts` is empty when the container starts, the entrypoint runs `ssh-keyscan` automatically as a fallback, but a pre-seeded file is safer.

> **Local host** (`172.28.0.1` — the Docker bridge gateway): the bridge doesn't exist until `make up`, so you cannot pre-seed it. A blind scan on first boot is acceptable for your own machine over a local bridge.

### 5. Build the agent image

Build the image once before first use:

```bash
make build AGENT=openclaw       # or claudecode, hermes-agent
```

### 6. Start the agent

```bash
make up AGENT=openclaw          # starts OpenClaw container + nginx dashboard at http://localhost:8090
make up AGENT=claudecode        # starts Claude Code container (headless)
make up AGENT=hermes      # starts Hermes Agent (NousResearch) interactive CLI

ssh-keyscan -H 172.28.0.1 >> .ssh/known_hosts
```

`make up` does three things in order:
1. Runs a security check (verifies seccomp profile is present and Docker supports it)
2. Starts the agent container via Docker Compose
3. Applies the FORWARD chain firewall rules via sudo (restricts SSH egress to config.json IPs)

The container entrypoint then:
1. Configures the internal iptables egress firewall (allows npm, GitHub, Anthropic API only)
2. Sets up the SSH directory in tmpfs (copies key, generates `~/.ssh/config`, scans known_hosts)
3. Drops from root to the agent user (`openclaw`, `node`, or `hermes`) via `gosu`
4. Starts `ssh-agent` as the agent user, loads the private key, locks the key file (`chmod 000`)
5. Execs the agent process (fully unprivileged — no effective Linux capabilities)

### 7. Set up target hosts

This installs the SSH chroot jail and the agent's public key on the target server.

**Local host** (the machine running Docker — accessed via the Docker bridge):
```bash
make setup HOST=my-server       # chroot + key install + sshd reload in one step

make restart AGENT=agent-name
make test HOST=my-server        # verify: should print "dev-bot"
```

**Remote host** via SSH (`chroot` or `restricted_key` mode):
```bash
make remote-setup HOST=my-server REMOTE_KEY=/path/to/admin/key [REMOTE_USER=ubuntu]
make test HOST=my-server
```

`REMOTE_KEY` is your personal admin key (used once to SSH into the server and configure it). `REMOTE_USER` defaults to `ubuntu`; for RunPod and similar use `root`.

**After adding a new host** to `config.json`, re-apply the firewall to pick up the new IP:
```bash
make firewall
```

### 8. Onboard OpenClaw (openclaw agent only)

```bash
docker exec -it agent-dev bash
openclaw onboard
```

Set the gateway port to `18789` and bind mode to `LAN`. Copy the token shown, paste it in the dashboard at `http://localhost:8090`, then approve the device:

```bash
openclaw devices list
openclaw devices approve <device-id>
```

The dashboard is available only at `http://localhost:8090` — it is bound to `127.0.0.1` and protected by basic auth.

### 9. Verify all security layers

```bash
make preflight
```

Checks: seccomp profile present, FORWARD chain firewall active, container running, correct capabilities set.

---

## Optional security hardening

### Chroot egress filter (strongly recommended)

Add `"chroot_egress_filter": true` to each host in `config.json`, then re-run setup:

```bash
make setup HOST=my-server    # or make remote-setup for remote hosts
```

This installs iptables rules on the remote host that restrict the chroot user's outbound traffic to DNS + HTTPS to package registries only. Without this, a compromised agent can use `curl`/`wget`/`python3` inside the chroot to exfiltrate data to arbitrary internet endpoints — bypassing both the container's internal firewall and the host FORWARD chain (which only restrict the container's network namespace, not the remote server's).

### Rootless Docker inside chroot (opt-in)

Add `"docker_access": true` to a host in `config.json`, then re-run setup. The agent gets a rootless Docker daemon scoped to its user namespace — it can `docker pull` and `docker run`, but cannot reach the host Docker daemon or run `--privileged` containers.

---

## Day-to-day operations

```bash
make logs                          # tail container logs
make status                        # show container status
make restart AGENT=<agent>         # restart + re-apply firewall
make down                          # stop container

make sync HOST=my-server           # re-push SSH key (after make keys on a new machine)
make key-add HOST=my-server        # alias for sync
make key-remove HOST=my-server     # remove SSH key from host
make chroot-clean HOST=my-server   # tear down chroot jail
```

---

## Command reference

| Command | Description |
|---------|-------------|
| `make keys` | Generate SSH keys + create data directories |
| `make auth` | Initialize dashboard credentials |
| `make build AGENT=<a>` | Build the container image |
| `make up AGENT=<a>` | Start container + apply firewall |
| `make down` | Stop running container |
| `make restart AGENT=<a>` | Restart container + re-apply firewall |
| `make logs` | Follow container logs |
| `make status` | Show container status |
| `make preflight` | Verify all security layers |
| `make setup HOST=<h>` | Full local host setup: chroot + key + sshd reload |
| `make chroot HOST=<h>` | Set up chroot jail only |
| `make chroot-clean HOST=<h>` | Tear down chroot jail |
| `make key-add HOST=<h>` | Install SSH key to host |
| `make key-remove HOST=<h>` | Remove SSH key from host |
| `make sync HOST=<h>` | Re-sync SSH key (alias for key-add) |
| `make test HOST=<h>` | Test SSH connection to host |
| `make remote-setup HOST=<h> REMOTE_KEY=<k>` | Set up chroot on a remote host |
| `make remote-clean HOST=<h> REMOTE_KEY=<k>` | Tear down chroot on a remote host |
| `make firewall` | Re-apply FORWARD chain firewall |
| `make firewall-flush` | Remove all FORWARD chain firewall rules |
| `make uninstall` | Full uninstall (keeps images and config) |
| `make purge` | Destructive full cleanup including config files |

---

## Troubleshooting

**Container won't start / permission denied on SSH key**

The SSH key must be owned by the agent user or root, and must not have group/world write bits. Run `make keys` to reset permissions. If the issue persists, check `docker logs agent-dev` for the specific error.

**Firewall rules not applied**

Run `make firewall` manually. If the container IP can't be detected (common with rootless Docker), set `EXPECTED_AGENT_IP=172.28.0.10` in `.env`.

**SSH connection refused / host key mismatch**

Pre-seed known_hosts: `ssh-keyscan -H <hostname> >> .ssh/known_hosts`, then `make restart AGENT=<agent>`.

**Agent can't reach a host**

Check that the host is in `config.json` and the firewall has been re-applied: `make firewall`. Verify with `make test HOST=<name>`.

**`make test` fails with "connection refused"**

The chroot or SSH key may not be set up. Run `make setup HOST=<name>` for local hosts or `make remote-setup HOST=<name> REMOTE_KEY=<key>` for remote hosts.

**Dashboard not accessible**

Verify nginx is running (`make status`) and you're using `http://localhost:8090` — it's bound to localhost only. Credentials were printed by `make auth`; run it again to regenerate them.

For port-forwarding and SSH tunnel configuration, see [SSH_TUNNELS.md](SSH_TUNNELS.md).
