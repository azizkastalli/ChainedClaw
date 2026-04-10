# OpenClaw Security Guide

This document outlines the security architecture for the OpenClaw dev setup.
It reflects the **actual implemented state** — aspirational items are tracked in
the [Hardening Roadmap](#hardening-roadmap) section.

## Security Architecture

### Defense Layers (Implemented)

1. **Container Hardening** — `read_only` filesystem, `cap_drop: ALL`, `no-new-privileges`, non-root user
2. **Host-Level Firewall** — Egress filtering on FORWARD chain, scoped to container IP, persistent by default
3. **Chroot Isolation** — Agent users are jailed in isolated directories on SSH hosts
4. **SSH Key-Only Auth** — Ed25519 keys generated on host, mounted read-only into container
5. **Host Key Pinning** — `known_hosts` pre-seeded at startup, `StrictHostKeyChecking yes`
6. **Dashboard Authentication** — Nginx basic auth, localhost binding only
7. **Static IP Assignment** — Container IPs are static, validated by firewall

### Container Security

The OpenClaw container runs as **non-root user (UID 1000)** with significant restrictions:

| Setting | Value | Purpose |
|---------|-------|---------|
| `user` | 1000:1000 | Non-root process — reduced privilege surface |
| `read_only` | true | Immutable root filesystem — prevents binary tampering and persistence |
| `cap_drop` | ALL | No Linux kernel capabilities (no `CAP_NET_ADMIN`, `CAP_SYS_ADMIN`, etc.) |
| `no-new-privileges` | true | Prevents privilege escalation via setuid binaries |
| `tmpfs` | /tmp, /run | Ephemeral writable dirs required by the gateway process |

**Writable paths (bind mounts):**
- `/home/openclaw/.openclaw` — Agent state, config, conversation history, npm cache
- `/home/openclaw/.ssh` — SSH config (generated at runtime from config.json)

**Read-only mounts:**
- `/home/openclaw/.ssh/id_openclaw` — SSH private key (host-managed)
- `/home/openclaw/.ssh/id_openclaw.pub` — SSH public key (host-managed)
- `/home/openclaw/.ssh/known_hosts` — Host keys (host-managed)
- `/config.json` — SSH host configuration
- `/entrypoint.sh` — Container startup script

All other filesystem paths are read-only. An attacker who compromises the
container cannot modify gateway binaries, system libraries, or plant persistence.

**Environment variables:**
- `NPM_CONFIG_CACHE=/home/openclaw/.openclaw/npm-cache` — Isolated npm cache directory

### Network Topology

```
Host Machine
│
└── openclaw-net (bridge, IPv6 disabled)
    ├── openclaw (172.28.0.10) ← SSH bridge to remote hosts
    └── nginx (172.28.0.20)    ← Reverse proxy (localhost:8090 only)
```

Both containers share a single Docker bridge network with:
- **IPv6 disabled** — No IPv6 attack surface
- **Static IPs** — Predictable addresses for firewall rules
- **Nginx bound to localhost** — No external dashboard access

### Host Firewall (FORWARD chain)

Egress filtering is applied on the host's `FORWARD` chain, scoped to the
OpenClaw container's static IP.

**Rule order (per container IP):**

| Priority | Rule | Action |
|----------|------|--------|
| 1 | Established/Related connections from container | ACCEPT |
| 2 | SSH (port 22) to each IP in `config.json` | ACCEPT |
| 3 | All other SSH from container | DROP |

**Key features:**
- **Only affects OpenClaw container** — Other containers and host services are NOT affected
- **Static IP validation** — Firewall validates container IP matches expected value
- **Persistent by default** — Rules survive reboots (use `--no-persist` to disable)

**Note:** In default mode, non-SSH traffic (HTTP, DNS, etc.) is not filtered.
Use `--block-all` mode to restrict all outbound traffic. See
[Firewall Management](#firewall-management) for details.

### Chroot Isolation (on SSH hosts)

When the agent SSHes into a host, it lands in a chroot jail:

```
/srv/chroot/openclaw-bot/
├── bin/, lib/, lib64/        ← bind-mounted read-only from host
├── usr/lib, usr/lib64/       ← bind-mounted read-only from host
├── usr/bin/                  ← SYMLINKS to host (SSH/network tools EXCLUDED)
├── proc/, sys/               ← mounted read-only (dedicated filesystems)
├── dev/null, dev/zero, dev/pts ← minimal device nodes
├── etc/                      ← MINIMAL passwd/group (no host user info)
│   ├── passwd                ← Only root, nobody
│   └── group                 ← Only root, nogroup
└── home/openclaw-bot/        ← bind-mounted READ-WRITE to project_paths
    ├── project1/             ← /path/to/project1
    └── project2/             ← /path/to/project2
```

**SSH/network binaries EXCLUDED from chroot:**
- `ssh`, `scp`, `sftp` — Prevent jumping to other hosts
- `ssh-keygen`, `ssh-keyscan`, `ssh-agent`, `ssh-add` — Prevent key operations
- `nc`, `netcat`, `ncat`, `telnet`, `rsh`, `rlogin` — Prevent network tunneling

**sshd restrictions for the agent user:**
- `ChrootDirectory` — Jailed to `/srv/chroot/openclaw-bot`
- `X11Forwarding no` — No X11 tunneling
- `AllowTcpForwarding no` — No port forwarding
- `PermitTunnel no` — No tunnel device

**Security improvements:**
- **SSH binaries removed via symlinks** — Agent cannot SSH to other hosts from within chroot
- **Minimal /etc/passwd** — No host user information leaked
- **curl, wget, python3 available** — Required for agent development work

### SSH Key Management

SSH keys are generated and managed on the **host**, not inside the container:

```
.ssh/                          ← In project root (bind-mounted)
├── id_openclaw                ← Private key (600)
├── id_openclaw.pub            ← Public key (644)
└── known_hosts                ← Host keys (644)
```

**Benefits:**
- Keys never exist in a writable location inside the container
- Key rotation doesn't require container rebuild
- Keys can be backed up independently

**Setup:**
```bash
sudo bash scripts/ssh_key/init_keys.sh
```

### Dashboard Authentication

The web dashboard is protected by HTTP Basic Authentication:

- **Nginx basic auth** — Username/password required
- **Localhost binding only** — `127.0.0.1:8090`, no external access
- **Health endpoint exempt** — `/health` accessible without auth

**Setup:**
```bash
sudo bash scripts/nginx/init_htpasswd.sh
```

---

## Quick Start

### 1. Configure Environment

```bash
cp .env.example .env
# Edit .env — fill in your settings
```

### 2. Initialize SSH Keys (on host)

```bash
sudo bash scripts/ssh_key/init_keys.sh
```

### 3. Initialize Dashboard Auth (on host)

```bash
sudo bash scripts/nginx/init_htpasswd.sh
```

### 4. Start Services

```bash
docker compose up -d
```

### 5. Set Up Firewall

```bash
sudo bash scripts/firewall/setup_firewall.sh
```

### 6. Set Up Chroot on Target Hosts

On each host that openclaw will SSH into:

```bash
sudo bash scripts/chroot_jail/jail_set.sh my-host
sudo systemctl reload sshd
```

### 7. Verify

```bash
docker exec -it openclaw ssh my-host whoami
# Expected: openclaw-bot
```

Open the dashboard at `http://localhost:8090` (credentials from step 3).

---

## Security Checklist

### Container Security
- [x] Container runs with `read_only: true` (immutable root filesystem)
- [x] All capabilities dropped (`cap_drop: ALL`)
- [x] `no-new-privileges` security option enabled
- [x] Container runs as non-root user (UID 1000)
- [x] Config and entrypoint mounted read-only into container
- [x] SSH keys mounted read-only (host-managed)
- [x] Nginx runs with read-only config mount
- [x] npm cache isolated to bind-mounted directory

### Network Security
- [x] Firewall egress filtering on FORWARD chain
- [x] Firewall rules persisted by default (survive reboots)
- [x] Static IP assignment with validation
- [x] IPv6 disabled in Docker network
- [x] Dashboard only accessible from localhost (127.0.0.1 binding)
- [x] Dashboard protected by basic auth

### Secret Management
- [x] `.env` file NOT committed to version control (see `.gitignore`)
- [x] `.env.example` template committed (no secrets, safe to commit)
- [x] SSH key auth only (no passwords)
- [x] SSH keys generated on host, not in container
- [x] SSH keys mounted read-only into container

### Host Security (requires sudo on SSH target)
- [x] Chroot jail configured for agent user
- [x] `/proc` and `/sys` mounted read-only inside chroot
- [x] TCP forwarding and tunneling disabled in sshd
- [x] SSH binaries excluded from chroot (symlink-based approach)
- [x] Minimal `/etc/passwd` in chroot (no host user info)
- [x] Firewall rules persist across reboots (default)

---

## Without Remote sudo

If you don't have sudo on the SSH target machine, you **cannot** set up the
chroot jail. The agent will still work — it SSHes in as a regular user — but
it has full filesystem visibility limited only by that user's Unix permissions.

**Mitigations without chroot:**
- Add restrictions in `~/.ssh/authorized_keys` on the remote host:
  ```
  command="/bin/bash",no-X11-forwarding,no-port-forwarding,no-pty ssh-ed25519 AAAA... openclaw-agent
  ```
- Use `rssh` (restricted shell) if available on the remote
- The host firewall still limits container egress regardless

---

## Firewall Management

### Apply Rules (persistent by default)
```bash
sudo bash scripts/firewall/setup_firewall.sh
```

### Apply Rules Without Persistence
```bash
sudo bash scripts/firewall/setup_firewall.sh --no-persist
```

### Auto-Reload on config.json Changes
```bash
sudo bash scripts/firewall/setup_firewall.sh --watch
```

### Block ALL Non-SSH Outbound (strictest)
```bash
sudo bash scripts/firewall/setup_firewall.sh --block-all
```

### Remove All Firewall Rules
```bash
sudo bash scripts/firewall/setup_firewall.sh --flush
```

### Verify Active Rules
```bash
sudo iptables -L FORWARD -n -v | grep OPENCLAW-FIREWALL
```

---

## Blast Radius Analysis

If the OpenClaw container is compromised:

| Attack Vector | Impact | Mitigated? |
|---------------|--------|------------|
| Read SSH private key | Cannot — read-only mount | ✅ Host-managed keys |
| SSH to allowed hosts | Can access project files in chroot | ✅ Chroot + firewall |
| SSH to other IPs | Blocked by firewall | ✅ FORWARD chain DROP |
| Modify gateway binary | Cannot — read-only filesystem | ✅ `read_only: true` |
| Plant persistence | Cannot — no writable system paths | ✅ `read_only: true` + `cap_drop` |
| Escalate to host | Cannot — no capabilities + non-root | ✅ `cap_drop: ALL` + `no-new-privileges` + UID 1000 |
| Access nginx directly | Possible — same network | ⚠️ Not segmented |
| Exfiltrate via HTTP/HTTPS | Possible in default firewall mode | ⚠️ Use `--block-all` |
| Access dashboard | Requires auth + localhost | ✅ Basic auth + 127.0.0.1 binding |
| SSH from chroot to other hosts | Cannot — SSH binaries excluded | ✅ Symlink exclusion |

### Residual Risks

1. **No network segmentation** — Nginx and OpenClaw share the same Docker network. A
   compromise of either container allows direct access to the other.
2. **ssh-keyscan at startup** — First-run host key pinning happens via
   `ssh-keyscan`, which is vulnerable to MITM on the local network. Keys are
   pinned after first scan and verified on subsequent connections.
   **Mitigation:** Pre-seed `known_hosts` manually for high-security environments.
3. **Non-SSH egress not blocked by default** — HTTP/HTTPS/DNS traffic is allowed.
   Use `--block-all` for strict egress control.

---

## Hardening Roadmap

These items are not currently implemented but could be added for stronger
security:

| Item | Effort | Benefit | Notes |
|------|--------|---------|-------|
| DMZ network segmentation | Medium | Medium | Separate nginx (dmz) from openclaw (internal) |
| HTTPS for dashboard | Low | Low (dev) | Self-signed certs; only useful if accessed remotely |
| SSH binary blocking in chroot | Done | High | ✅ Implemented — symlink exclusion approach |
| IPv6 firewall rules | Done | Low | ✅ Implemented — IPv6 disabled in Docker network |

---

## Reporting Security Issues

If you discover a security vulnerability, please report it responsibly by
opening a private security advisory on the project repository.
