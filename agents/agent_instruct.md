# Agent Instructions

## Available Remote Hosts

Your SSH configuration is at `~/.ssh/config`. Each host entry includes comments
showing where project directories are mounted in the remote workspace.

Connect to a host:

    ssh <host-name>

## Workspace Layout

For `container`-isolated hosts, you land inside a secure workspace container as
user `dev-bot`. Project directories are bind-mounted from the host:

- Projects are mounted at `~/workspace/<project-name>` (e.g. `~/workspace/openhere-hermes`)

For `restricted_key` hosts (e.g. RunPod), you connect directly to the host
filesystem. Depending on `project_access` mode:

- `acl` — project paths are accessible at the paths shown in the comments (in-place access via ACLs)
- `copy` — project files were copied into `~/workspace/<basename>` at setup time
- `clone` — repos were cloned from GitHub into `~/workspace/<repo-name>` (e.g. `~/workspace/GeoProj`)

## Git Repositories (GitHub deploy keys)

Some project directories are backed by GitHub repositories. When that's the case,
a repo-scoped GitHub **deploy key** is already provisioned for `dev-bot` on the
remote host — you can `git fetch` / `git pull` / (when `github_write: true`)
`git push` without any extra setup.

Where things live on the remote host (as `dev-bot`):

- **SSH client config:** `~/.ssh/config` — contains one `Host github.com-<slug>`
  alias per repo (the slug is just the repo name, e.g.
  `GeoProj`)
- **Deploy keys:** `~/.ssh/deploy_keys/<slug>/id_ed25519` (mounted read-only in
  container mode; copied into place in `restricted_key` mode)
- **URL rewrites:** `~/.gitconfig` has `url."git@github.com-<slug>:owner/repo.git".insteadOf "git@github.com:owner/repo.git"`
  entries, so standard GitHub SSH remotes (`git@github.com:owner/repo.git`) are
  transparently rewritten to use the correct deploy key. You don't need to edit
  remotes — existing clones and fresh clones both work.

Notes:

- Deploy keys are **repo-scoped**: each key only grants access to the single
  repo it was provisioned for. Do not attempt to use one repo's key for another.
- If `git push` fails with `Repository not found`, check `git remote -v` — if
  the remote is HTTPS rather than SSH, switch it to `git@github.com:owner/repo.git`
  so the `insteadOf` rewrite applies.
- Write access depends on the per-repo `github_write` flag in the host config.
  If a push is rejected as read-only, that repo was provisioned read-only on
  purpose — ask the user rather than trying to bypass it.

## Notes

- `ssh`, `scp`, `nc`, and other network tools are not available inside workspace containers
- Your SSH key is pre-loaded — `ssh <host-name>` works without a passphrase
- You cannot pivot from a workspace container to another host
- Do not attempt to write outside the mounted project paths
