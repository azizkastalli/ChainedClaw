# OpenClaw Workspace Image
#
# Runs on the REMOTE HOST (not the agent host). The agent SSHes into the host
# as `dev-bot`; sshd ForceCommand routes the session into a long-lived container
# built from this image via `docker exec`.
#
# SSH/network-pivot binaries (ssh, scp, nc, telnet, rsh, socat) are intentionally
# NOT installed — matches the chroot exclusion list. An agent hijacked by prompt
# injection cannot lateral-move to another host from this container.
#
# Docker CLI is installed so that when docker_access: true is set in config.json,
# the workspace can talk to the host-side rootless Docker daemon via a
# bind-mounted socket. No daemon runs inside the workspace itself.

FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      wget \
      git \
      jq \
      python3 \
      python3-pip \
      python3-venv \
      build-essential \
      pkg-config \
      nodejs \
      npm \
      less \
      nano \
      vim \
      unzip \
      tar \
      gzip \
      procps \
      iproute2 \
      file \
      locales \
      tzdata \
      docker.io \
      docker-compose-plugin \
  && rm -rf /var/lib/apt/lists/* \
  && apt-get clean

# Remove SSH/network-pivot tools if any transitively installed package pulled them in.
# Fail open: missing binaries are not an error.
RUN for bin in ssh scp sftp ssh-keygen ssh-keyscan ssh-agent ssh-add \
               nc netcat ncat telnet rsh rlogin socat; do \
      rm -f "/usr/bin/$bin" "/bin/$bin" 2>/dev/null || true; \
    done

# Create dev-bot user with fixed UID/GID matching the host-side user.
# The container is launched with --user <host-uid>:<host-gid> at runtime, so this
# baked-in UID is only a fallback for interactive debugging.
ARG DEV_BOT_UID=1001
ARG DEV_BOT_GID=1001
RUN groupadd -g "$DEV_BOT_GID" dev-bot && \
    useradd -m -u "$DEV_BOT_UID" -g "$DEV_BOT_GID" -s /bin/bash dev-bot && \
    mkdir -p /home/dev-bot/workspace && \
    chown -R dev-bot:dev-bot /home/dev-bot

# Keep the container alive; docker exec is how sessions actually run.
USER dev-bot
WORKDIR /home/dev-bot/workspace
CMD ["sleep", "infinity"]
