FROM ghcr.io/astral-sh/uv:0.11.6-python3.13-trixie@sha256:b3c543b6c4f23a5f2df22866bd7857e5d304b67a564f4feab6ac22044dde719b AS uv_source
FROM tianon/gosu:1.19-trixie@sha256:3b176695959c71e123eb390d427efc665eeb561b1540e82679c15e992006b8b9 AS gosu_source
FROM debian:13.4

# Disable Python stdout buffering to ensure logs are printed immediately
ENV PYTHONUNBUFFERED=1

# Store Playwright browsers outside the volume mount so the build-time
# install survives the /opt/data volume overlay at runtime.
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/hermes/.playwright

# Install system dependencies in one layer, clear APT cache
# Added firewall tools: iptables, ipset, iproute2, dnsutils, aggregate, jq, curl
# Added SSH tools: openssh-client
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        build-essential nodejs npm python3 ripgrep ffmpeg gcc python3-dev libffi-dev procps git \
        iptables ipset iproute2 dnsutils aggregate jq curl openssh-client && \
    rm -rf /var/lib/apt/lists/*

# Non-root user for runtime; UID matches host user (1000) for bind mount compatibility
RUN useradd -u 1000 -m -d /opt/data hermes

COPY --chmod=0755 --from=gosu_source /gosu /usr/local/bin/
COPY --chmod=0755 --from=uv_source /usr/local/bin/uv /usr/local/bin/uvx /usr/local/bin/

WORKDIR /opt/hermes

# ---------- Layer-cached dependency install ----------
# Copy only package manifests first so npm install + Playwright are cached
# unless the lockfiles themselves change.
# Paths are relative to hermes-agent/ submodule directory.
COPY hermes-agent/package.json hermes-agent/package-lock.json ./
COPY hermes-agent/scripts/whatsapp-bridge/package.json hermes-agent/scripts/whatsapp-bridge/package-lock.json scripts/whatsapp-bridge/
COPY hermes-agent/web/package.json hermes-agent/web/package-lock.json web/

RUN npm install --prefer-offline --no-audit && \
    npx playwright install --with-deps chromium --only-shell && \
    (cd scripts/whatsapp-bridge && npm install --prefer-offline --no-audit) && \
    (cd web && npm install --prefer-offline --no-audit) && \
    npm cache clean --force

# ---------- Source code ----------
# .dockerignore excludes node_modules, so the installs above survive.
COPY --chown=hermes:hermes hermes-agent/ .

# Build web dashboard (Vite outputs to hermes_cli/web_dist/)
RUN cd web && npm run build

# ---------- Python virtualenv ----------
RUN chown hermes:hermes /opt/hermes
USER hermes
RUN uv venv && \
    uv pip install --no-cache-dir -e ".[all]"

# ---------- Security: Internal firewall ----------
USER root
# Copy init-firewall.sh from build context (agents/hermes/../init-firewall.sh)
COPY init-firewall.sh /usr/local/bin/init-firewall.sh
RUN chmod +x /usr/local/bin/init-firewall.sh

# Copy custom entrypoint that runs firewall + SSH setup + privilege drop
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Pre-create SSH directories so entrypoint can write into them
RUN mkdir -p /home/hermes/.ssh-keys /home/hermes/.ssh && \
    chown -R hermes:hermes /home/hermes/.ssh-keys /home/hermes/.ssh

# ---------- Runtime ----------
ENV HERMES_WEB_DIST=/opt/hermes/hermes_cli/web_dist
ENV HERMES_HOME=/opt/data
VOLUME [ "/opt/data" ]
ENTRYPOINT [ "/entrypoint.sh" ]
