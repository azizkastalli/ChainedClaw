FROM nousresearch/hermes-agent@sha256:d634f4a65c65a2e4ed60d5711570911c378beac89a988f38872898e41da31265

# gosu is already in the official image.
# Add tools required by entrypoint.sh: firewall init + SSH key setup.
USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
    iptables ipset iproute2 dnsutils aggregate jq curl openssh-client tmux \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Entrypoint: firewall init + SSH setup + privilege drop → start-hermes.sh
COPY entrypoint.sh /entrypoint.sh
COPY start.sh /usr/local/bin/start-hermes.sh
RUN chmod +x /entrypoint.sh /usr/local/bin/start-hermes.sh

# Pre-create SSH working dirs (tmpfs overlays ~/.ssh at runtime, but the dir
# must exist in the image layer so Docker can mount tmpfs over it)
RUN mkdir -p /home/hermes/.ssh-keys /home/hermes/.ssh && \
    chown -R hermes:hermes /home/hermes/.ssh-keys /home/hermes/.ssh

# Pre-create .local directory for hermes state (gateway locks, etc.)
RUN mkdir -p /home/hermes/.local/state/hermes && \
    chown -R hermes:hermes /home/hermes/.local
