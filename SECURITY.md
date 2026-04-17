# OpenClaw Security Model

The openclaw container is treated as **fully compromised at all times**. Every layer
is designed around: *"If the agent is hijacked via prompt injection, what can it reach?"*

---

## What a compromised agent can and cannot do

| Can | Cannot |
|-----|--------|
| SSH to hosts in `config.json` | SSH to hosts not in `config.json` (FORWARD chain) |
| Access `project_paths` on those hosts | Access other host filesystem paths (chroot) |
| Forward ports listed in `forward_ports` | Forward unlisted ports (`PermitOpen`) |
| Use rootless Docker on remote hosts (if `docker_access: true`) | Reach host Docker daemon (rootless Docker uses user namespace) |
| Reach npm, GitHub, Anthropic API | Reach arbitrary internet IPs (internal firewall) |
| — | Steal SSH private key (loaded into `ssh-agent`, key file `chmod 000`) |
| — | Replace SSH keys (`.ssh-keys` is read-only) |
| — | Write to container filesystem (openclaw: `read_only: true`) |
| — | Exfiltrate data via DNS tunneling (DNS restricted to Docker resolver) |

---

## Security Layers

Both agents share the same base layers. openclaw carries one additional restriction
(`read_only: true`) because it runs third-party code; claudecode is Anthropic's own tool.

### Container Hardening

| Control | openclaw | claudecode | Protects against |
|---|---|---|---|
| `cap_drop: ALL` + seccomp | ✅ | ✅ | Kernel exploit, privilege escalation |
| `read_only: true` | ✅ | ✗ | Persistence of compromise in container layer |
| `no-new-privileges` | ✅ | ✗ | setuid/setgid escalation (claudecode needs sudo for firewall) |
| `.ssh-keys` read-only | ✅ | ✅ | SSH key replacement and known_hosts tampering |
| `ssh-agent` key loading | ✅ | ✅ | Private key exfiltration (key file `chmod 000` after loading) |
| `tmpfs /tmp /run ~/.ssh` | ✅ | ✅ | Temp file persistence across restarts |
| Resource limits | ✅ 2g | ✅ 4g | CPU/memory DoS |
| No host Docker socket | ✅ | ✅ | Host Docker daemon unreachable |
| No host filesystem mounts | ✅ | ✅ | Host files unreachable |
| Internal firewall (init-firewall.sh) | ✅ | ✅ | Unrestricted internet egress |

**Note on openclaw `read_only: true`:** tmpfs covers `/tmp`, `/run`, `~/.ssh`. If the
agent needs additional write paths, add them as tmpfs entries in docker-compose.yaml.

**Note on claudecode:** `read_only` and `no-new-privileges` are not set — the node
user needs sudo for iptables (init-firewall.sh). Host isolation is provided entirely
by `cap_drop: ALL` + seccomp profile.

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
SSH outbound is also allowed (needed for chroot host access).

**DNS is restricted to Docker's internal resolver** (`127.0.0.11` only). This prevents
DNS exfiltration tunnels where a compromised agent encodes data in DNS queries to
attacker-controlled nameservers.

The allowlist is defined in `agents/init-firewall.sh`. If openclaw needs additional
endpoints (Telegram, custom APIs), add them there.

### Firewall (iptables FORWARD chain)

Applied automatically on `make up` / `make restart`. Restricts SSH egress from the
container to IPs listed in `config.json`. Rules persist across reboots.

### Host Chroot (SSH path)

| Control | Effect |
|---|---|
| `ChrootDirectory` | Agent sees only `project_paths` |
| SSH/network tools stripped | Cannot lateral-move to other hosts |
| `docker` excluded from chroot by default | Cannot reach host Docker daemon |
| `/proc`, `/sys` read-only | No kernel manipulation |
| `AllowTcpForwarding local` or `no` | Controlled by `forward_ports` per host |
| `PermitOpen localhost:PORT` | Port allowlist enforced at protocol level |
| `PermitTunnel no` | No VPN tunnelling |
| `ClientAliveInterval 300` | Idle SSH sessions auto-closed after 15 min |
| `ClientAliveCountMax 3` | — |
| `MaxSessions 3` | Limits concurrent SSH sessions |

### Project Directory Permissions

For the chroot user to write to project directories owned by a host user, `jail_set.sh`
automatically:

1. **Detects the host user's group** from the first `project_path` directory
2. **Adds the chroot user to that group** (supplementary group membership)
3. **Sets group-write permissions** on project directories (`chmod -R g+w`)

This allows the agent to edit files while maintaining security:
- The agent remains isolated in the chroot (cannot access other host paths)
- File ownership stays with the host user (not transferred to agent)
- Group membership is the minimum privilege needed for write access

**Prerequisite:** Project directories must be owned by a group that the host user belongs to
(typically the user's primary group, e.g., `aziz:aziz`). If project directories have different
ownership, you may need to manually:
```bash
sudo chown -R <host-user>:<host-user> /path/to/project
sudo chmod -R g+w /path/to/project
```

`PermitOpen` is the definitive port-forward enforcement — the remote sshd rejects
requests to any unlisted destination regardless of what the client sends.

### Chroot Egress Filter (opt-in)

**Per-host config:** `"chroot_egress_filter": true` in `config.json`

When enabled, `scripts/chroot_jail/chroot_egress_filter.sh` installs iptables rules
on the remote host that restrict outbound traffic from the chroot user's UID:

| Allowed | Blocked |
|---------|---------|
| Loopback | All other outbound from chroot user |
| Established connections (SSH return) | `curl`/`wget` to arbitrary URLs |
| DNS (port 53) | Raw socket connections |
| HTTPS to package registries (npm, PyPI, GitHub) | Data exfiltration via custom protocols |

This closes the most critical remaining attack path: even though `curl`/`wget`/`python3`
are available inside the chroot (needed for development work), the egress filter
prevents them from reaching anything other than allowed destinations.

### Rootless Docker (opt-in)

**Per-host config:** `"docker_access": true` in `config.json`

When enabled, `scripts/chroot_jail/setup_rootless_docker.sh` sets up a rootless Docker
daemon for the chroot user on the remote host:

```
Agent container ──SSH──► chroot (dev-bot)
                            │
                            │ docker CLI
                            ▼
                    /run/user/<uid>/docker.sock  ← bind-mount from host
                            │
                    ┌───────▼──────────┐
                    │ rootless dockerd │  ← runs as dev-bot OUTSIDE chroot
                    │ (user namespace) │     cannot reach host Docker
                    └──────────────────┘     cannot run --privileged
```

| Property | Effect |
|----------|--------|
| User namespace isolation | Container root ≠ host root |
| No host Docker socket | Cannot affect host containers |
| `--privileged` rejected | No host device access |
| `--pid=host` rejected | No host process visibility |
| `--network=host` rejected | No host network access |

**When `docker_access: false` (default):** The `docker` binary is excluded from the
chroot's `/usr/bin` symlinks, preventing any Docker usage.

### Dashboard (nginx)

Basic auth on all routes. Bound to `127.0.0.1:8090` only. `.htpasswd` uses `chmod 640`
to prevent world-readable credential hashes.

---

## Blast Radius

```
prompt injection → agent
  → SSH to config.json hosts only (FORWARD chain firewall)
    → project_paths only (chroot)
    → localhost:PORT only (PermitOpen)
    → [if docker_access: true] rootless Docker only (user namespace — no host escape)
    → [if chroot_egress_filter: true] DNS + registry HTTPS only (egress filter)
    → [if chroot_egress_filter: false] ⚠️ curl/wget/python3 can reach any remote endpoint
  → internet: npm, GitHub, api.anthropic.com only (internal firewall)
    DNS: Docker resolver only (no DNS exfiltration)
    (add openclaw-specific domains to agents/init-firewall.sh as needed)
  → SSH private key: locked in ssh-agent (not readable as file)
```

---

## Known Limitations

### HIGH — Network tools available in chroot (without egress filter)

The chroot provides `curl`, `wget`, `python3`, and other network-capable tools that
the agent needs for development work. Without the chroot egress filter, a compromised
agent can use these to exfiltrate `project_paths` data to arbitrary internet endpoints
from the remote server — bypassing both the container's internal firewall and the
host FORWARD chain (those only restrict the container's network namespace).

**Mitigation:** Enable `chroot_egress_filter: true` in `config.json` per host.
This restricts outbound from the chroot user to DNS + HTTPS to known registries only.

---

### HIGH — Unfiltered Docker image pulls (with docker_access: true)

The agent can `docker pull` from any registry via rootless Docker. A malicious image
runs inside the rootless user namespace (cannot escape host) but can mine CPU or
stage data for exfiltration.

**Fix:** Combine with `chroot_egress_filter: true` to restrict registry access to
`docker.io`, `ghcr.io`, `quay.io` only.

---

### MEDIUM — SSH tunnel binds to `0.0.0.0`

For Playwright debugging the agent binds `-L 0.0.0.0:PORT:localhost:PORT` so inner
Docker containers can reach the tunnel via the inner bridge gateway. This also makes
the forwarded port reachable from nginx on `agent-dev-net`.

**Fix:** Bind to the inner Docker bridge gateway IP only (e.g. `172.17.0.1`) instead
of `0.0.0.0`, scoping the listener to inner containers only.

---

### MEDIUM — No audit trail

No logging of SSH commands run in chroot, Docker images pulled, ports forwarded, or
external IPs contacted. A compromised agent leaves no forensic record.

**Fix:** `LogLevel VERBOSE` in the sshd Match block (logs chroot commands on remote
server). `auditd` on the openclaw host watching the container's cgroup. Ship logs to
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