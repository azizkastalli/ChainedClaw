FROM ghcr.io/openclaw/openclaw:latest

# Install tools required by init-firewall.sh and entrypoint.sh.
# Assumes a Debian/Ubuntu base.
USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
  iptables \
  ipset \
  iproute2 \
  dnsutils \
  aggregate \
  jq \
  python3 \
  curl \
  gosu \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

# Rename the base image's 'node' user (uid 1000) to 'openclaw'.
# useradd -u 1000 fails because uid 1000 is already taken by 'node'.
RUN usermod -l openclaw -d /home/openclaw -m node && groupmod -n openclaw node

# Internal container firewall — restricts outbound to allowed domains only.
# Same script as claudecode; extend EXTRA_ALLOWED_DOMAINS in docker-compose if
# openclaw needs additional endpoints (e.g. Telegram, custom APIs).
COPY init-firewall.sh /usr/local/bin/init-firewall.sh
RUN chmod +x /usr/local/bin/init-firewall.sh

# Pre-create SSH directories so entrypoint can write into them
# even when the container filesystem is read-only (directories exist in image layer).
RUN mkdir -p /home/openclaw/.ssh-keys /home/openclaw/.ssh
