#!/bin/sh
#
# SSH session entry point — invoked by the ForceCommand= in authorized_keys.
# Installed at /usr/local/bin/openclaw-session-entry on the remote host.
#
# Every SSH session from the agent lands here. We route the session into the
# named long-lived workspace container via `docker exec`. The agent never
# gets a shell on the real host filesystem.
#
# $1 is the container name. $SSH_ORIGINAL_COMMAND is set by sshd from the
# client's remote command (empty for interactive sessions).
#
# Rootless Docker is used, so DOCKER_HOST points at the per-user socket.
set -eu

CONTAINER="$1"
if [ -z "$CONTAINER" ]; then
    echo "openclaw-session-entry: missing container name" >&2
    exit 2
fi

AGENT_UID=$(id -u)
export DOCKER_HOST="unix:///run/user/${AGENT_UID}/docker.sock"
export PATH="$HOME/bin:$PATH"

if ! docker inspect --type=container "$CONTAINER" >/dev/null 2>&1; then
    echo "openclaw-session-entry: container '$CONTAINER' not found" >&2
    exit 3
fi

if ! docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -qx true; then
    docker start "$CONTAINER" >/dev/null
fi

if [ -z "${SSH_ORIGINAL_COMMAND:-}" ]; then
    exec docker exec -it "$CONTAINER" bash -l
else
    exec docker exec -i "$CONTAINER" bash -lc "$SSH_ORIGINAL_COMMAND"
fi
