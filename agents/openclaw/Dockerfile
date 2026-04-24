# Stage 1: Get Chromium from Microsoft Playwright image
# This avoids downloading Chromium during build (network blocked)
FROM mcr.microsoft.com/playwright:v1.50.0-noble AS playwright-base

# Stage 2: Build openclaw agent image with Chromium
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

# Install Playwright client (browser is copied from playwright-base)
RUN npm install -g playwright@1.50.0

# Rename the base image's 'node' user (uid 1000) to 'openclaw'.
# This must happen BEFORE we copy files to /home/openclaw.
RUN usermod -l openclaw -d /home/openclaw -m node && groupmod -n openclaw node

# Copy Chromium from Microsoft Playwright image to openclaw's home directory.
# This ensures the openclaw user can access the browser.
COPY --from=playwright-base /ms-playwright /home/openclaw/.cache/ms-playwright

# Install Chromium dependencies (libs, fonts, etc.)
# These are required for Chromium to run
RUN npx playwright install-deps chromium

# Fix ownership of the Playwright cache so openclaw user can access it.
RUN chown -R openclaw:openclaw /home/openclaw/.cache

# Create symlink so browser tools can find Chromium.
# Points to openclaw's home directory (not root's).
RUN ln -s /home/openclaw/.cache/ms-playwright/chromium-1155/chrome-linux/chrome /usr/bin/chromium && \
    chmod +x /home/openclaw/.cache/ms-playwright/chromium-1155/chrome-linux/chrome

# Internal container firewall — restricts outbound to allowed domains only.
# Same script used by all agents. Add extra endpoints via allowed_domains in config.json.
COPY init-firewall.sh /usr/local/bin/init-firewall.sh
RUN chmod +x /usr/local/bin/init-firewall.sh
COPY agent_instruct.md /home/openclaw/agent_instruct.md

# Pre-create SSH directories so entrypoint can write into them
# even when the container filesystem is read-only (directories exist in image layer).
RUN mkdir -p /home/openclaw/.ssh-keys /home/openclaw/.ssh && \
    chown -R openclaw:openclaw /home/openclaw/.ssh-keys /home/openclaw/.ssh