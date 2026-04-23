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
filesystem — project paths are accessible at the paths shown in the comments.

## Notes

- `ssh`, `scp`, `nc`, and other network tools are not available inside workspace containers
- Your SSH key is pre-loaded — `ssh <host-name>` works without a passphrase
- You cannot pivot from a workspace container to another host
- Do not attempt to write outside the mounted project paths
