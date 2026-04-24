# OpenClaw Security Model

The agent container is treated as **fully compromised at all times** — regardless of which agent runs inside. Every layer is designed around: *"If the agent is hijacked via prompt injection, what can it reach?"*

---

## What a compromised agent can and cannot do

| Can | Cannot |
|-----|--------|
| SSH to hosts in `config.json` | SSH to hosts not in `config.json` (FORWARD chain) |
| Access `project_paths` on those hosts | Access paths outside `project_paths` (workspace container namespace) |
| Forward ports listed in `forward_ports` | Forward unlisted ports (`PermitOpen`) |
| Use filtered Docker access on remote hosts (if `docker_access: true`) | Reach host Docker daemon (proxy blocks privileged operations) |
| Reach npm, GitHub, Anthropic API | Reach arbitrary internet IPs (internal firewall) |
| — | Steal SSH private key (loaded into `ssh-agent`, key file `chmod 000`) |
| — | Replace SSH keys (`.ssh-keys` is read-only) |
| — | Write to container filesystem (openclaw agent: `read_only: true`) |
| — | Exfiltrate data via DNS tunneling (DNS restricted to Docker resolver) |

---

## Security Layers

All agents share the same base security layers. The openclaw agent carries one additional restriction
(`read_only: true`) because it runs third-party code; claudecode and hermes are
treated as more trusted (first-party / known-source tools). Custom agents can opt into
the same hardening by setting `read_only: true` in their service definition.

### Container Hardening

| Control | openclaw | claudecode | hermes-agent | Protects against |
|---|---|---|---|---|
| `cap_drop: ALL` + seccomp | ✅ | ✅ | ✅ | Kernel exploit, privilege escalation |
| `read_only: true` | ✅ | ✗ | ✗ | Persistence of compromise in container layer |
| `no-new-privileges` | ✅ | ✗ | ✗ | setuid/setgid escalation (needs sudo for firewall) |
| `.ssh-keys` read-only | ✅ | ✅ | ✅ | SSH key replacement and known_hosts tampering |
| `ssh-agent` key loading | ✅ | ✅ | ✅ | Private key exfiltration (key file `chmod 000` after loading) |
| `tmpfs /tmp /run ~/.ssh` | ✅ | ✅ | ✅ | Temp file persistence across restarts |
| Resource limits | ✅ 2g | ✅ 4g | ✅ 4g | CPU/memory DoS |
| No host Docker socket | ✅ | ✅ | ✅ | Host Docker daemon unreachable |
| No host filesystem mounts | ✅ | ✅ | ✅ | Host files unreachable |
| Internal firewall (init-firewall.sh) | ✅ | ✅ | ✅ | Unrestricted internet egress |

**Note on `read_only: true` (openclaw agent):** tmpfs covers `/tmp`, `/run`, `~/.ssh`. If the
agent needs additional write paths, add them as tmpfs entries in docker-compose.yaml.

**Note on claudecode / hermes:** `read_only` and `no-new-privileges` are not set —
the agent user needs to write to its runtime directories (config, venv cache, session data).
Host isolation is provided entirely by `cap_drop: ALL` + seccomp profile.

### SSH Key Protection (ssh-agent)

The private key is loaded into an in-memory `ssh-agent` at container startup, then the
key file is `chmod 000`. This means:
- ✅ SSH connections work normally via `SSH_AUTH_SOCK`
- ✅ Agent cannot `cat`/`less`/`cp` the private key
- ⚠️ Agent can still use the key to SSH (by design)
- ⚠️ A sophisticated attacker could extract the key from `ssh-agent` memory via `/proc`
  — but this requires `ptrace` capability, which is blocked by `cap_drop: ALL` + seccomp

### Internal Firewall (init-firewall.sh)

Runs inside each agent's own network namespace on container start. Restricts all outbound
connections to an allowlist: npm registry, GitHub, `api.anthropic.com`, Sentry, Statsig.
SSH outbound is also allowed (needed for workspace host access).

**DNS is restricted to Docker's internal resolver** (`127.0.0.11` only). This prevents
DNS exfiltration tunnels where a compromised agent encodes data in DNS queries to
attacker-controlled nameservers.

The core allowlist is defined in `agents/init-firewall.sh`. To allow additional endpoints
(e.g. OpenAI, Exa, Telegram, custom APIs), add them to the `allowed_domains` array in
`config.json` — no changes to `init-firewall.sh` are needed.

### Firewall (iptables FORWARD chain)

Applied automatically on `make up` / `make restart`. Restricts SSH egress from the
container to IPs listed in `config.json`. Rules persist across reboots.

### Workspace Container / SSH Path (`container` isolation)

| Control | Effect |
|---|---|
| Rootless Docker container | Agent sees only bind-mounted `project_paths` via filesystem namespace |
| SSH/network tools stripped from image | Cannot lateral-move to other hosts |
| Docker proxy filters operations | Cannot reach host Docker daemon; `--privileged` / `network=host` / dangerous caps blocked |
| `/proc`, `/sys` not mounted | No kernel manipulation surface |
| `AllowTcpForwarding local` or `no` | Controlled by `forward_ports` per host |
| `PermitOpen localhost:PORT` | Port allowlist enforced at protocol level |
| `PermitTunnel no` | No VPN tunnelling |
| `ClientAliveInterval 300` | Idle SSH sessions auto-closed after 15 min |
| `ClientAliveCountMax 3` | — |
| `MaxSessions 3` | Limits concurrent SSH sessions |

### `restricted_key` Isolation

In `restricted_key` mode no workspace container is provisioned. The agent SSHes as
`dev-bot` with a key restricted to `restrict,pty`. Access to `project_paths` is
governed by `project_access` (ACL grants or copy).

> **Weaker than `container` mode.** ACL and copy modes do not provide filesystem
> namespace isolation. World-readable directories (mode `755`) remain accessible to
> `dev-bot` regardless of ACL grants. Use `container` isolation for machines that hold
> personal or sensitive data outside `project_paths`.

### Workspace Egress Filter (opt-in)

**Per-host config:** `"egress_filter": true` in `config.json`

When enabled, `scripts/workspace/egress_filter.sh` installs iptables rules on the
remote host that restrict outbound traffic from the workspace user's UID:

| Allowed | Blocked |
|---------|---------|
| DNS (port 53) | Arbitrary HTTP/HTTPS |
| HTTPS to npm, PyPI, GitHub, Docker Hub, quay.io | Raw socket connections |
| Established connections (SSH return traffic) | Data exfiltration via custom protocols |

This closes the most critical remaining attack path: even though `curl`, `wget`, and
`python3` are available in the workspace (needed for development work), the egress
filter prevents them from reaching anything other than allowed destinations.

### Docker Access (opt-in)

**Per-host config:** `"docker_access": true` in `config.json`

When enabled, a Docker socket proxy (`docker_proxy.py`) is started on the remote host.
The agent accesses Docker through this proxy, which enforces:

```
Agent container ──SSH──► workspace (dev-bot)
                            │
                            │ docker CLI → DOCKER_HOST proxy socket
                            ▼
                    /run/openclaw/docker.sock  ← filtered proxy
                            │
                    ┌───────▼──────────────┐
                    │ docker_proxy.py      │  enforces:
                    │ (runs as root)       │  • bind mounts: project_paths only
                    └──────────────────────┘  • --privileged: blocked
                            │               • network=host: blocked
                            ▼               • dangerous caps: blocked
                    /var/run/docker.sock (real socket)
```

| Property | Effect |
|----------|--------|
| Proxy enforces bind-mount allowlist | Only `project_paths` can be mounted |
| `--privileged` rejected | No host device access |
| `--network=host` rejected | No host network access |
| Dangerous capabilities blocked | No kernel privilege escalation |

The agent never has access to the real Docker socket.

### Dashboard (nginx)

Basic auth on all routes. Bound to `127.0.0.1:8090` only. `.htpasswd` uses `chmod 640`
to prevent world-readable credential hashes.

### Playwright Browser Service (opt-in)

**Profile:** `openclaw` (started automatically with openclaw agent)

A separate container running Playwright with Chromium, isolated from the agent:

```
Agent container (172.28.0.10) ──CDP──► Playwright (172.28.0.40:9222)
                                           │
                                           ▼
                                    Chromium (sandboxed)
```

| Property | Effect |
|----------|--------|
| Separate container | Browser isolated from agent process |
| `cap_drop: ALL` | No Linux capabilities |
| `no-new-privileges` | No privilege escalation |
| Internal network only | No external network access |
| No host mounts | Cannot reach host filesystem |

**Usage:** The agent connects via `PLAYWRIGHT_BROWSERS_SERVER=http://playwright-browser:9222`

**Security benefit:** Even if a web page exploits Chromium, the attacker:
- Cannot reach the agent container's filesystem
- Cannot reach the host
- Has no network access beyond the internal Docker network

---

## Blast Radius

```
prompt injection → agent
  → SSH to config.json hosts only (FORWARD chain firewall)
    → project_paths only (workspace container filesystem namespace)
    → localhost:PORT only (PermitOpen)
    → [if docker_access: true] filtered Docker only (proxy — no --privileged, no host bind mounts)
    → [if egress_filter: true] DNS + registry HTTPS only (egress filter)
    → [if egress_filter: false] ⚠️ curl/wget/python3 can reach any remote endpoint
  → internet: npm, GitHub, api.anthropic.com only (internal firewall)
    DNS: Docker resolver only (no DNS exfiltration)
    (add agent-specific domains to config.json allowed_domains as needed)
  → SSH private key: locked in ssh-agent (not readable as file)
```

---

## Known Limitations

### HIGH — Network tools available in workspace (without egress filter)

The workspace provides `curl`, `wget`, `python3`, and other network-capable tools that
the agent needs for development work. Without the egress filter, a compromised agent
can use these to exfiltrate `project_paths` data to arbitrary internet endpoints from
the remote server — bypassing both the container's internal firewall and the host
FORWARD chain (those only restrict the container's network namespace).

**Mitigation:** Enable `egress_filter: true` in `config.json` per host.
This restricts outbound from the workspace user to DNS + HTTPS to known registries only.

---

### HIGH — Unfiltered Docker image pulls (with docker_access: true)

The agent can `docker pull` from any registry via the Docker proxy. A malicious image
runs as the workspace user (cannot escape host) but can mine CPU or stage data for
exfiltration.

**Fix:** Combine with `egress_filter: true` to restrict registry access to
`docker.io`, `ghcr.io`, `quay.io` only.

---

### HIGH — `restricted_key` mode: weaker filesystem isolation

In `restricted_key` mode, ACL and copy modes do not prevent `dev-bot` from reading
world-readable directories on the host (mode `755`). A compromised agent can browse
other users' home directories if they are world-readable.

**Mitigation:** Use `container` isolation for machines with personal or sensitive data.
For `restricted_key` on shared machines, remove world-read from parent directories:
```bash
chmod o-r /home/youruser/Desktop
```

---

### MEDIUM — SSH tunnel binds to `0.0.0.0`

For Playwright debugging the agent binds `-L 0.0.0.0:PORT:localhost:PORT` so inner
Docker containers can reach the tunnel via the inner bridge gateway. This also makes
the forwarded port reachable from nginx on `agent-dev-net`.

**Fix:** Bind to the inner Docker bridge gateway IP only (e.g. `172.17.0.1`) instead
of `0.0.0.0`, scoping the listener to inner containers only.

---

### MEDIUM — No audit trail

No logging of SSH commands run in workspace, Docker images pulled, ports forwarded, or
external IPs contacted. A compromised agent leaves no forensic record.

**Fix:** `LogLevel VERBOSE` in the sshd Match block (logs workspace commands on remote
server). `auditd` on the host machine watching the container's cgroup. Ship logs to
a write-once destination so the agent cannot tamper with them.

---

### MEDIUM — seccomp profile uses allowlist-by-denial

The seccomp profile uses `defaultAction: SCMP_ACT_ALLOW` with a blocklist. New Linux
kernel syscalls are automatically permitted. This is weaker than a deny-by-default
model with an explicit allowlist, but is more maintainable across kernel versions.

**Current mitigation:** `cap_drop: ALL` + no `runtime: sysbox-runc` provides strong
defense-in-depth. The seccomp blocklist adds a supplementary layer.

---

### LOW — known_hosts blind scan on first boot

If `known_hosts` is empty when the container starts, `entrypoint.sh` runs
`ssh-keyscan` — a MITM window. Pre-seeding before `make up` eliminates this.

**Fix:** Have `entrypoint.sh` refuse to start if a configured host has no
`known_hosts` entry, making pre-seeding mandatory rather than advisory.

---

### LOW — `config.json` readable inside the container

The agent can read `/config.json` (all hostnames, ports, paths). It cannot act
on hosts not already configured, but it reduces reconnaissance effort.

**Fix:** Mount only the derived SSH config (generated by `entrypoint.sh`) rather
than the raw `config.json`.

---

### LOW — `eval exec "$AGENT_CMD"` in entrypoint

The entrypoint uses `eval` on the `AGENT_CMD` environment variable for shell quote
parsing. While `AGENT_CMD` is set in docker-compose.yaml (not user input), this is
technically a code injection surface if the Docker environment is compromised.

**Accepted risk:** `AGENT_CMD` is operator-controlled, not agent-controlled. Replacing
`eval` would require a dispatch table for known agent commands.
