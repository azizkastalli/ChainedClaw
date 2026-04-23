# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Project Is

**OpenClaw** (also called ChainedClaw) is a Docker-based AI agent platform with an SSH bridge. It runs AI agents (OpenClaw, Claude Code, or Hermes) in hardened containers with a defense-in-depth security model designed around one assumption: **the agent container may be compromised at any time via prompt injection**. Every security layer is built to limit blast radius given that assumption.

---

## Key Commands

```bash
# Initial setup
cp .env.example .env && cp config.example.json config.json
make keys       # Generate Ed25519 SSH keys + create data dirs
make auth       # Create nginx .htpasswd (prints dashboard credentials)

# Build and run (only one agent runs at a time — same container name/IP)
make build AGENT=openclaw       # or claudecode, hermes
make up AGENT=openclaw          # start container + apply iptables FORWARD chain
make down                       # stop the running container

# Daily operations
make logs                       # follow container logs
make status                     # show compose status
make restart AGENT=<agent>      # restart + re-apply firewall
make preflight                  # verify all security layers are active (seccomp, firewall, caps)

# Shell into running container
make shell                      # opens bash as the agent user with SSH_AUTH_SOCK set

# Local host workspace setup
make setup HOST=my-server       # full: workspace container + key + sshd reload
make test HOST=my-server        # verify SSH (should print "dev-bot")

# Remote host workspace setup
make remote-setup HOST=my-server REMOTE_KEY=/path/to/admin-key [REMOTE_USER=ubuntu]
make test HOST=my-server

# Key management
make sync HOST=my-server        # re-push SSH key (after re-keying)
make firewall                   # re-apply FORWARD chain (run after adding hosts to config.json)

# Destructive cleanup
make uninstall                  # full uninstall, keeps images and config
make purge                      # destructive: removes containers, keys, data dirs
```

---

## Architecture

### Three Isolated Agent Modes

All three agents share the same Docker container name (`agent-dev`), static IP (`172.28.0.10`), and Docker network (`agent-dev-net`). Only one runs at a time. The mode is selected with `AGENT=`:

| Mode | Agent process | Dashboard? | Data dir |
|------|--------------|------------|----------|
| `openclaw` | `openclaw gateway run` | nginx `:8090` | `.openclaw-data/` |
| `claudecode` | `claude --auto-approve` | None | `.claudecode-data/` |
| `hermes` | `/usr/local/bin/start-hermes.sh` | nginx `:8090` | `.hermes-data/` |

### Container Boot Sequence

`entrypoint.sh` (runs as root) does the following before dropping privileges:
1. Runs `agents/init-firewall.sh` — installs internal iptables egress allowlist inside the container's network namespace
2. Validates the SSH private key at `.ssh/id_agent` (bind-mounted read-only)
3. Copies the key to `tmpfs ~/.ssh/`, generates `~/.ssh/config` from `config.json` (Python script inline), seeds `known_hosts`
4. Drops to `AGENT_USER` via `gosu`
5. Starts `ssh-agent`, loads the key, `chmod 000`s the key file
6. `exec`s `AGENT_CMD`

### Security Layers (layered, defense-in-depth)

| Layer | Where | What it restricts |
|-------|-------|-------------------|
| Container internal firewall (`init-firewall.sh`) | Inside container, runs at boot | Outbound to npm, GitHub, `api.anthropic.com`, Sentry, Statsig; DNS to Docker resolver only |
| Host FORWARD chain firewall (`setup_firewall.sh`) | Host iptables, applied on `make up/restart` | SSH egress from container locked to IPs in `config.json` only |
| Seccomp profile (`security/seccomp-agent.json`) | Docker | Blocks dangerous syscalls (mount, unshare, ptrace, bpf, etc.) |
| `cap_drop: ALL` + selective `cap_add` | Docker | NET_ADMIN/NET_RAW for iptables in entrypoint; SETUID/SETGID for gosu drop; all cleared after exec |
| Workspace container (`workspace_up.sh`) | Remote/local host | Agent sessions routed into a rootless-Docker container via `ForceCommand`; SSH/network tools excluded from image; project_paths bind-mounted |
| `PermitOpen` in sshd | Remote host | Port forwarding limited to `forward_ports` list per host |
| `ssh-agent` key locking | Inside container | Key loaded in-memory, file `chmod 000` — agent can SSH but cannot read the key |

### `config.json` — Central Config File

This file is the single source of truth for which hosts are accessible. It is mounted read-only into the container at `/config.json` and consumed by three components:
- `entrypoint.sh` — generates `~/.ssh/config` from it
- `init-firewall.sh` — allows SSH egress to those IPs
- `setup_firewall.sh` (host-side) — locks the FORWARD chain to those IPs

**Key fields per host:**

| Field | Notes |
|-------|-------|
| `isolation` | `container` (standard) or `restricted_key` (managed environments like RunPod without sudo) |
| `project_paths` | Host directories bind-mounted into the workspace container — agent access limited to these paths |
| `forward_ports` | Port-forward allowlist enforced by `PermitOpen` in sshd |
| `egress_filter` | Opt-in: UID-keyed iptables on the remote host restricting workspace-user outbound to DNS + registries only |
| `docker_access` | Opt-in: bind-mount the rootless Docker socket into the workspace container (user namespace — cannot reach host Docker) |
| `allowed_domains` | Top-level array: extra domains added to the container's egress allowlist |

### Workspace Container Layout

The workspace container (`agents-workspace:latest`, built from `agents/workspace/Dockerfile`) runs on the remote host as a long-lived rootless-Docker container. Sessions enter it via `docker exec` — the agent never gets a shell on the real host.

- `project_paths` are bind-mounted RW at `/home/dev-bot/<basename>`
- `forward_ports` are published to `127.0.0.1` on the host
- SSH/network-pivot binaries are stripped from the image: `ssh`, `scp`, `sftp`, `nc`, `netcat`, `telnet`, `rsh`, `socat`

### Hermes Agent Specifics

Hermes runs a Python venv at `/opt/hermes/.venv` inside the container. Agent data persists to `.hermes-data/` (bind-mounted to `/opt/data`). To interact:

```bash
docker exec -it -u hermes agent-dev bash
source /opt/hermes/.venv/bin/activate
hermes --help
```

API keys (`ANTHROPIC_API_KEY`, `OPENROUTER_API_KEY`, `OPENAI_API_KEY`) are passed via `.env` into the container environment.

---

## Key Files

| File | Role |
|------|------|
| `config.json` | SSH hosts, port-forward allowlists, extra egress domains |
| `.env` | Ports, container names, UIDs, API keys — never committed |
| `scripts/entrypoint.sh` | Shared container boot script for openclaw and claudecode |
| `agents/init-firewall.sh` | Internal egress firewall (ipset + iptables, runs at container start) |
| `scripts/firewall/setup_firewall.sh` | Host FORWARD chain firewall (applied by `make up`) |
| `scripts/workspace/workspace_up.sh` | Provisions workspace container + sshd Match block on target host |
| `scripts/workspace/workspace_down.sh` | Tears down workspace container and sshd Match block |
| `scripts/workspace/session_entry.sh` | ForceCommand target: routes SSH sessions into workspace container via `docker exec` |
| `scripts/workspace/egress_filter.sh` | UID-keyed egress filter on remote host (opt-in via `egress_filter: true`) |
| `agents/workspace/Dockerfile` | Workspace container image (runs on remote host, not agent host) |
| `security/seccomp-agent.json` | Seccomp blocklist applied to all agent containers |
| `agents/hermes/Dockerfile` | Hermes-specific image (separate build context from openclaw/claudecode) |
| `docker-compose.yaml` | All three agent services under named profiles; nginx on `openclaw`/`hermes` profiles |
