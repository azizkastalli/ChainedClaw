#  Contained - an AI-Agent Security Framework

Security infrastructure for running AI agents in zero-trust isolation. Drop in any agent — Claude Code, OpenClaw gateway, Hermes, or your own — and get hardened containers, egress control, and SSH-gated workspace access on remote servers. Every layer is designed around one assumption: **the agent container may be compromised at any time**.

→ [Full reference](docs/REFERENCE.md) — config fields, make targets, troubleshooting
→ [Security model](docs/SECURITY.md) — threat model, layers, known limitations

---

## Prerequisites

- Docker + Docker Compose v2
- `sudo` access on the host (iptables firewall + workspace setup)
- Docker seccomp support: `docker info | grep seccomp`

---

## Quick Setup

### 1. Configure

```bash
cp .env.example .env
cp config.example.json config.json
```

Edit `config.json` to define your SSH hosts:

```json
{
  "ssh_hosts": [
    {
      "name": "my-server",
      "hostname": "192.168.1.100",
      "port": 22,
      "isolation": "container",
      "project_paths": ["/path/to/project"]
    }
  ]
}
```

### 2. Generate keys and credentials

```bash
make keys    # Ed25519 SSH keys + data directories
make auth    # dashboard credentials — save the output
```

### 3. Build and start

```bash
make build AGENT=claudecode    # or: openclaw, hermes
make up AGENT=claudecode
```

### 4. Set up target hosts

```bash
# Local host (machine running Docker)
make workspace-setup HOST=my-server

# Remote host
make workspace-setup HOST=my-server REMOTE_KEY=~/.ssh/admin-key [REMOTE_USER=ubuntu]
```

### 5. Verify

```bash
make test HOST=my-server    # should print "dev-bot"
make preflight              # verify all security layers are active
```

---

## Supported agents

Three agents ship out of the box. All share the same container name, IP, and firewall rules — only one runs at a time.

| Agent | Command | Notes |
|-------|---------|-------|
| Claude Code | `make up AGENT=claudecode` | Anthropic CLI, headless |
| OpenClaw gateway | `make up AGENT=openclaw` | OpenClaw gateway + nginx dashboard at `:8090` |
| Hermes | `make up AGENT=hermes` | NousResearch Hermes + dashboard at `:8090` |

Switching agents: `make down` then `make up AGENT=<other>`.

Adding your own agent: add a new service to `docker-compose.yaml` with the same network and container name, set `AGENT_USER` and `AGENT_CMD`, and give it a new profile.

---

## Common commands

```bash
make logs                                           # tail container logs
make restart AGENT=<agent>                          # restart + re-apply firewall
make workspace-clean HOST=<h>                       # tear down local workspace
make workspace-clean HOST=<h> REMOTE_KEY=<k>        # tear down remote workspace
make workspace-purge HOST=<h> REMOTE_KEY=<k>        # full remote purge (removes dev-bot user)
make sync HOST=<h>                                  # re-push SSH key after re-keying
make firewall                                       # re-apply FORWARD chain (after adding hosts)
``` 
