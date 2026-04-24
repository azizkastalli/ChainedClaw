# OpenClaw — Reference

## Architecture

```
┌────────────────────────────────────────────────────────────┐
│  Host machine                                              │
│                                                            │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  agent-dev container  (uid 1000, no capabilities)    │  │
│  │                                                      │  │
│  │  agent process  (openclaw / claude / hermes / custom)│  │
│  │    ↳ internal firewall (iptables)                    │  │
│  │      npm, GitHub, Anthropic API only                 │  │
│  └───────────────────┬──────────────────────────────────┘  │
│                      │ SSH ed25519 (key in ssh-agent)      │
│                      ▼                                     │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  workspace container  (rootless Docker, dev-bot uid) │  │
│  │    no SSH/network tools · project_paths bind-mounted │  │
│  │    sshd ForceCommand → docker exec (no host shell)   │  │
│  │    PermitOpen enforces port-forward allowlist        │  │
│  └──────────────────────────────────────────────────────┘  │
│                                                            │
│  Host iptables FORWARD chain                               │
│    SSH egress from agent → config.json hosts only          │
└────────────────────────────────────────────────────────────┘
```

---

## config.json field reference

### Top-level

| Field | Required | Description |
|-------|----------|-------------|
| `ssh_hosts` | Yes | Array of host definitions |
| `allowed_domains` | No | Extra domains added to the agent container's egress allowlist |

### Per-host fields

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| `name` | Yes | — | Short alias used in SSH config and make targets |
| `hostname` | Yes | — | IP or hostname of the target server |
| `port` | No | `22` | SSH port |
| `user` | No | `root` | SSH user on the target host |
| `strict_host_key_checking` | No | `true` | Set to `false` only for ephemeral hosts |
| `isolation` | Yes | — | `container` or `restricted_key` — see below |
| `project_paths` | Yes | — | Host directories the agent may access |
| `forward_ports` | No | `[]` | Ports the agent may tunnel to itself — `container` mode only |
| `egress_filter` | No | `false` | Lock workspace outbound to DNS + package registries only |
| `docker_access` | No | `false` | Give the agent filtered Docker access inside the workspace |
| `project_access` | No | `acl` | `restricted_key` only — `acl` or `copy` — see below |

---

## Isolation modes

### `container` (standard)

Provisions a rootless-Docker workspace container on the target host. Every SSH session from the agent is routed into the container via `ForceCommand` — the agent never gets a shell on the real host filesystem.

- `project_paths` are bind-mounted read-write into the container at `~/workspace/<basename>`
- SSH/network-pivot tools (`ssh`, `nc`, `socat`, etc.) are stripped from the workspace image
- `PermitOpen` in sshd enforces the `forward_ports` allowlist at the protocol level
- Use for: standard VMs, bare-metal servers, local machine

### `restricted_key` (managed environments)

No workspace container. The agent SSHes as `dev-bot` with a restricted key (`restrict,pty`). Access to `project_paths` is governed by `project_access`.

- Use for: RunPod pods, managed containers where rootless Docker and sudo are unavailable
- Weaker isolation than `container` — see project_access section below

---

## project_access — `restricted_key` mode only

Controls how `dev-bot` gains access to `project_paths`. No effect in `container` mode.

| Value | How it works | Best for |
|-------|-------------|----------|
| `acl` (default) | POSIX ACLs on source paths + traverse ACLs on parent dirs. Projects are symlinked into `~/workspace/`. Agent edits appear in the original files immediately. | Dedicated remote machines (RunPod) with no other user data |
| `copy` | Project files are copied into `~/workspace/` under dev-bot ownership. No ACLs on source paths. Re-running setup rsyncs updates from source (without `--delete`). | When clean ownership matters and project size is manageable |

> **Security note — `restricted_key` on a shared machine:**
>
> Neither `acl` nor `copy` provides container-level filesystem isolation. Any directory
> that is world-readable on the host (e.g. mode `755`) remains accessible to dev-bot.
>
> - `acl` mode additionally grants traverse ACLs on parent directories so symlinks resolve,
>   which allows dev-bot to navigate into those parents.
> - `copy` mode grants no ACLs, but world-readable directories are still visible.
>
> **For a machine that also holds personal data, use `container` isolation.** The workspace
> container runs in its own filesystem namespace — dev-bot sees only what is explicitly
> bind-mounted, regardless of host file permissions.
>
> If you must use `restricted_key` on a shared machine, remove world-read from directories
> above the project path:
> ```bash
> chmod o-r /home/youruser/Desktop
> ```

---

## docker_access

When `true`, the agent can run `docker` and `docker compose` inside the workspace. Access is always filtered through a proxy (`docker_proxy.py`) that enforces:

- Bind mounts restricted to `project_paths` only
- `--privileged` blocked
- `network=host` blocked
- Dangerous capabilities blocked

The agent never has access to the real Docker socket.

In `container` mode the proxy socket is bind-mounted into the workspace container.
In `restricted_key` mode the proxy runs as root on the host; the socket is placed in `/run/openclaw/` (mode `700`, owned by `dev-bot`) so only dev-bot can reach it. `DOCKER_HOST` is written to `dev-bot`'s `.bashrc`, `.profile`, and `~/.ssh/environment`.

> **Note:** The proxy is a background process and does not survive host reboots. Re-run
> `make workspace-setup HOST=<h>` after a reboot to restart it.

---

## egress_filter

When `true`, iptables rules are installed on the remote host restricting outbound traffic from the workspace user (matched by UID) to DNS + HTTPS to package registries only. Because rootless Docker egress appears as that UID on the host, this covers both host processes and container traffic.

| Allowed | Blocked |
|---------|---------|
| DNS (port 53) | Arbitrary HTTP/HTTPS |
| HTTPS to npm, PyPI, GitHub, Docker Hub, quay.io | Raw socket connections |
| Established connections (SSH return traffic) | Data exfiltration via custom protocols |

Without this, a compromised agent can reach arbitrary internet endpoints from the workspace, bypassing both the container's internal firewall and the host FORWARD chain (which only restrict the agent container's network namespace).

---

## Make target reference

### Container management

| Target | Description |
|--------|-------------|
| `make build AGENT=<a>` | Build the container image |
| `make up AGENT=<a>` | Start container + apply FORWARD chain firewall |
| `make down` | Stop running container |
| `make restart AGENT=<a>` | Restart container + re-apply firewall |
| `make logs` | Follow container logs |
| `make status` | Show container status |
| `make shell` | Open a shell inside the container as the agent user |
| `make preflight` | Verify all security layers are active |
| `make security-check` | Check seccomp profile and Docker support |

### Workspace management

All workspace targets require `HOST=<name>`. Add `REMOTE_KEY=<path>` to target a remote host; optionally add `REMOTE_USER=<user>` (default: current user).

| Target | Local | Remote |
|--------|-------|--------|
| `make workspace-setup` | `workspace_up.sh` + key install + sshd reload | Copies scripts, runs setup remotely |
| `make workspace-clean` | `workspace_down.sh` + key remove + sshd reload | Tears down workspace remotely |
| `make workspace-purge` | Full teardown + removes dev-bot, Docker, ACLs | Same, remote |

### Key management

| Target | Description |
|--------|-------------|
| `make key-add HOST=<h>` | Install or refresh SSH key for HOST |
| `make key-remove HOST=<h>` | Remove SSH key for HOST |
| `make sync HOST=<h>` | Re-sync SSH key (alias for key-add) |
| `make test HOST=<h>` | Test SSH connection — should print "dev-bot" |
| `make ssh HOST=<h>` | Open an interactive shell on HOST as the agent would |

### Firewall

| Target | Description |
|--------|-------------|
| `make firewall` | Re-apply FORWARD chain (run after adding hosts to config.json) |
| `make firewall-flush` | Remove all FORWARD chain rules |

### Setup and cleanup

| Target | Description |
|--------|-------------|
| `make keys` | Generate Ed25519 SSH keys + create data directories |
| `make auth` | Initialize dashboard credentials |
| `make config` | Copy example config files if not present |
| `make uninstall` | Full uninstall — keeps images and config |
| `make purge` | Destructive full cleanup including config and data dirs |
| `make purge-data` | Remove agent data directories only |

---

## Day-to-day operations

```bash
# Restart and re-apply firewall after config changes
make restart AGENT=claudecode

# Re-push SSH key after make keys on a new machine
make sync HOST=my-server

# After adding a new host to config.json
make firewall

# Tear down and rebuild a workspace
make workspace-clean HOST=my-server
make workspace-setup HOST=my-server
```

---

## Troubleshooting

**Container won't start / permission denied on SSH key**
The SSH key must be owned by the agent user or root with no group/world write bits.
Run `make keys` to reset. Check `docker logs agent-dev` for details.

**Firewall rules not applied**
Run `make firewall` manually. If the container IP can't be detected, set
`EXPECTED_AGENT_IP=172.28.0.10` in `.env`.

**SSH connection refused / host key mismatch**
Pre-seed known_hosts: `ssh-keyscan -H <hostname> >> .ssh/known_hosts`, then `make restart AGENT=<agent>`.

**Agent can't reach a host**
Confirm the host is in `config.json` and the firewall has been re-applied: `make firewall`.
Verify with `make test HOST=<name>`.

**`make test` fails with "connection refused"**
Workspace is not set up. Run `make workspace-setup HOST=<name>` or
`make workspace-setup HOST=<name> REMOTE_KEY=<key>` for remote hosts.

**Dashboard not accessible**
Verify nginx is running (`make status`) and you're using `http://localhost:8090` —
it binds to localhost only. Credentials were printed by `make auth`.

**Docker proxy not working after host reboot (`restricted_key` + `docker_access`)**
The proxy is not persistent. Re-run `make workspace-setup HOST=<name>` to restart it.

For port-forwarding and tunnel configuration, see [SSH_TUNNELS.md](SSH_TUNNELS.md).
