# Migration: chroot → workspace container

This release replaces the old `isolation: "chroot"` mode with `isolation: "container"`.
The chroot scripts are deleted. All hosts previously configured with `"chroot"` must be
switched to `"container"` and re-provisioned.

If the old chroot setup broke permissions or left bind mounts on one of your hosts, run
the recovery steps at the bottom before re-provisioning.

---

## Why the change

The old `jail_set.sh` did three destructive things on the remote host:

1. `chmod -R g+w` on every `project_path` — rewrote permissions on your real files.
2. `usermod -aG` to put `dev-bot` into your project's group — altered host user membership.
3. Bind-mounted `/bin`, `/lib`, `/usr/lib`, `/usr/lib64` under `$CHROOT_BASE`, then symlinked
   individual binaries. Partial failures could leave dangling mounts; subsequent `rm -rf`
   of `$CHROOT_BASE` could damage the host filesystem.

The new `container` mode uses a long-lived rootless-Docker workspace container on the
remote host. `authorized_keys` gets a `ForceCommand` line routing every SSH session into
the container via `docker exec`. No system bind mounts, no `chmod`/`chown` on project
files, atomic setup and teardown.

---

## Migrating an existing host

```bash
# 1. Update config.json for the host:
#    - Rename "isolation": "chroot"          → "isolation": "container"
#    - Rename "chroot_egress_filter": true    → "egress_filter": true
#    (docker_access, forward_ports, project_paths all keep their names.)

# 2. Tear down the OLD chroot on the remote host.
#    Do this BEFORE pulling the new code if possible, while jail_break.sh still exists,
#    or use the manual recovery steps below if you've already updated.
sudo bash scripts/chroot_jail/jail_break.sh <host-name>     # only if scripts still exist

# 3. Pull the new code.
git pull

# 4. Provision the new workspace on the host.
make setup HOST=<host-name>                     # local host
# or
make remote-setup HOST=<host-name> REMOTE_KEY=<your-admin-key>

# 5. Verify.
make test HOST=<host-name>
```

---

## Manual recovery for a damaged host

If the old chroot setup is already in a broken state (typical symptoms: leftover
bind mounts under `/srv/chroot/dev-bot` or wherever `$CHROOT_BASE` pointed, project
files stuck in `g+w`, `dev-bot` still in your user's group), run the following on
the remote host as root. **Do this manually** — do not automate it; the paths
need to be inspected first.

### 1. Identify leftover mounts

```bash
# CHROOT_BASE is whatever your .env said (default: /srv/chroot/dev-bot).
mount | grep /srv/chroot/dev-bot
```

Expected to find bind mounts of `/bin`, `/lib`, `/lib64`, `/usr/lib`, `/usr/lib64`,
`/dev/pts`, plus `proc` and `sysfs` pseudo-filesystems, and each `project_path`
bound under `$CHROOT_BASE/home/dev-bot/<name>`.

### 2. Unmount deepest-first

```bash
CHROOT_BASE=/srv/chroot/dev-bot           # substitute your actual value
mount | grep "$CHROOT_BASE" | awk '{print $3}' | sort -r | \
    while read -r mp; do
        umount "$mp" 2>/dev/null || umount -l "$mp"
    done

# Verify nothing remains:
mount | grep "$CHROOT_BASE" && echo "STILL MOUNTED — investigate before continuing"
```

### 3. Remove the chroot directory (only after mounts are gone)

```bash
mount | grep -q "$CHROOT_BASE" && { echo "Refusing to delete — mounts still active"; exit 1; }
rm -rf "$CHROOT_BASE"
```

### 4. Revert project-directory permissions (optional)

The old setup ran `chmod -R g+w` on each `project_path`. If you want to roll that
back, replay your preferred permissions — e.g.:

```bash
sudo chmod -R g-w /path/to/project         # remove group-write
# or leave g+w if it doesn't actually bother you — the permissions aren't harmful
# on their own, just unexpected.
```

### 5. Remove dev-bot from project groups (optional)

The old setup added `dev-bot` to the group that owns your project directory. If
you want it out:

```bash
# List dev-bot's groups:
id dev-bot

# Remove from each non-primary group you want cleaned:
sudo gpasswd -d dev-bot <group-name>
```

### 6. Remove the sshd Match block

`workspace_up.sh` replaces the block automatically, but if you're recovering
without re-provisioning, strip it manually:

```bash
sudo sed -i '/# BEGIN Dev-Agent Chroot Configuration/,/# END Dev-Agent Chroot Configuration/d' \
    /etc/ssh/sshd_config
sudo systemctl reload sshd
```

### 7. Remove the old egress-filter iptables chain

```bash
sudo iptables -D OUTPUT -j AGENT-CHROOT-EGRESS 2>/dev/null
sudo iptables -F AGENT-CHROOT-EGRESS 2>/dev/null
sudo iptables -X AGENT-CHROOT-EGRESS 2>/dev/null
```

The new `egress_filter.sh` handles this flush automatically, but if you're just
recovering and not re-provisioning, run it yourself.

---

## What's preserved

- `restricted_key` mode is unchanged. Hosts using it do not need migration.
- `PermitOpen` for `forward_ports` still enforced at the sshd layer.
- UID-keyed egress filter logic is identical — only the chain name changed
  (`AGENT-CHROOT-EGRESS` → `AGENT-WORKSPACE-EGRESS`) and the config key
  (`chroot_egress_filter` → `egress_filter`). `workspace_up.sh` still reads the
  old key as a fallback so a half-migrated config doesn't silently disable it.
- Docker-in-Docker (`docker_access: true`) uses the same rootless-Docker socket
  pattern; no remote-host reinstall needed beyond re-running `make setup`.
