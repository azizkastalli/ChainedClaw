#!/bin/bash
#
# Provision a workspace for a host defined in config.json.
# Supports two isolation modes: container (rootless Docker) and restricted_key (ACL/copy).
#
# What this script does (all idempotent):
#   1. Creates AGENT_USER as a regular host user.
#   2. Installs and starts rootless Docker for AGENT_USER.
#   3. Builds the agents-workspace image from agents/workspace/Dockerfile.
#   4. Runs a long-lived container per host, with project_paths bind-mounted
#      RW and forward_ports published to 127.0.0.1 on the host.
#   5. Optionally bind-mounts the rootless Docker socket into the container
#      (docker_access: true — enables Docker-in-Docker for the agent).
#   6. Installs /usr/local/bin/openclaw-session-entry (ForceCommand target).
#   7. Appends a Match User block to sshd_config enforcing PermitOpen
#      for forward_ports. No ChrootDirectory anywhere.
#   8. Optionally applies the UID-keyed egress filter.
#
# What this script explicitly does NOT do:
#   - chmod anything under project_paths (those stay as the operator set them)
#   - usermod -aG to add AGENT_USER to project-file groups
#   - bind-mount /bin, /lib, /usr/lib, or any host system directory
#   - rm -rf anything outside the workspace Docker state
#
# Usage: workspace_up.sh <host-name>
#
set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

if [ "$EUID" -ne 0 ]; then
    log_error "Must run as root (sudo)"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENV_FILE="$PROJECT_ROOT/.env"
CONFIG_JSON="$PROJECT_ROOT/config.json"

if [ ! -f "$ENV_FILE" ]; then
    log_error ".env not found at $ENV_FILE"
    exit 1
fi
source "$ENV_FILE"

if [ -z "${1:-}" ]; then
    echo "Usage: $0 <host-name>"
    exit 1
fi
HOST_NAME="$1"

if ! command -v jq &>/dev/null; then
    log_error "jq is required. Install with: apt install jq"
    exit 1
fi

if ! command -v docker &>/dev/null && [ ! -x "/home/${AGENT_USER}/bin/docker" ]; then
    # Docker is needed to build/run the workspace image. The rootless installer
    # below will fetch it if missing, but warn up front.
    log_info "Docker CLI not found on PATH — will be installed by rootless setup."
fi

# ── Read per-host config ───────────────────────────────────────────────────────
ISOLATION=$(jq -r --arg name "$HOST_NAME" \
    '.ssh_hosts[] | select(.name == $name) | .isolation // "container"' \
    "$CONFIG_JSON")
[ -z "$ISOLATION" ] || [ "$ISOLATION" = "null" ] && ISOLATION="container"

if [ "$ISOLATION" != "container" ] && [ "$ISOLATION" != "restricted_key" ]; then
    log_error "Unknown isolation mode: '$ISOLATION'"
    log_error "Valid values: container, restricted_key"
    exit 1
fi

PROJECT_PATHS=$(jq -r --arg name "$HOST_NAME" \
    '.ssh_hosts[] | select(.name == $name) | .project_paths[]
     | if type == "string" then . else (.path // "") end' \
    "$CONFIG_JSON" | grep -v '^$' || true)
if [ -z "$PROJECT_PATHS" ]; then
    # clone mode has no local paths — GITHUB_REPOS drives everything.
    _pa=$(jq -r --arg name "$HOST_NAME" \
        '.ssh_hosts[] | select(.name == $name) | .project_access // "acl"' \
        "$CONFIG_JSON")
    if [ "$_pa" != "clone" ]; then
        log_error "No project_paths for host '$HOST_NAME' in config.json"
        exit 1
    fi
fi

# Extract project_paths entries that carry a github_repo (object form only).
GITHUB_REPOS=$(jq -c --arg name "$HOST_NAME" \
    '[.ssh_hosts[] | select(.name == $name)
      | .project_paths[]
      | select(type == "object" and (.github_repo // "") != "")
      | {path: .path, repo: .github_repo, slug: (.github_repo | gsub("/"; "-")), write: (.github_write // false)}
     ]' \
    "$CONFIG_JSON" 2>/dev/null || echo "[]")

# ── Helper: grant AGENT_USER access to project_paths via ACL ──────────────────
grant_project_acls() {
    while IFS= read -r path; do
        [ -z "$path" ] && continue
        if [ ! -d "$path" ]; then
            log_error "  project_path does not exist: $path"
            log_error "  Create it on the host before running this script."
            exit 1
        fi
        if ! su -s /bin/bash "$AGENT_USER" -c "test -r '$path' && test -w '$path'" 2>/dev/null; then
            log_info "  Granting $AGENT_USER rw access to $path via ACL..."
            if command -v setfacl &>/dev/null; then
                # Grant traverse (x) on each parent dir so the user can
                # resolve the path without being blocked mid-tree.
                _parent="$path"
                while [ "$_parent" != "/" ]; do
                    _parent="$(dirname "$_parent")"
                    if ! su -s /bin/bash "$AGENT_USER" -c "test -x '$_parent'" 2>/dev/null; then
                        setfacl -m "u:$AGENT_USER:x" "$_parent"
                        log_info "    traverse: $_parent"
                    fi
                done
                # Grant rw on the project dir itself; default ACL covers new files.
                setfacl -R  -m "u:$AGENT_USER:rwX" "$path"
                setfacl -Rd -m "u:$AGENT_USER:rwX" "$path"
                log_info "  ACL granted (new files will inherit access)"
            else
                log_warn "  setfacl not available — install acl package: apt install acl"
                log_warn "  Falling back: adding $AGENT_USER to $(stat -c %G "$path") group..."
                DIR_GROUP=$(stat -c %G "$path")
                usermod -aG "$DIR_GROUP" "$AGENT_USER"
                chmod -R g+rw "$path"
                chmod g+x "$(dirname "$path")"
                log_warn "  Group write set. SSH into $AGENT_USER may need a re-login to pick up group."
            fi
        else
            log_info "  $path — OK"
        fi
    done <<< "$PROJECT_PATHS"
}

# ── restricted_key: user + ACLs + optional Docker proxy, no workspace container ─
if [ "$ISOLATION" = "restricted_key" ]; then
    echo "=== Isolation: restricted_key (no workspace container) ==="
    if ! id "$AGENT_USER" &>/dev/null; then
        useradd -m -s /bin/bash "$AGENT_USER"
        log_info "User $AGENT_USER created"
    else
        log_info "User $AGENT_USER already exists"
    fi
    AGENT_UID=$(id -u "$AGENT_USER")
    AGENT_HOME=$(eval echo "~$AGENT_USER")

    _DOCKER_ACCESS=$(jq -r --arg name "$HOST_NAME" \
        '.ssh_hosts[] | select(.name == $name) | .docker_access // false' \
        "$CONFIG_JSON")
    [ "$_DOCKER_ACCESS" = "null" ] && _DOCKER_ACCESS="false"

    PROJECT_ACCESS=$(jq -r --arg name "$HOST_NAME" \
        '.ssh_hosts[] | select(.name == $name) | .project_access // "acl"' \
        "$CONFIG_JSON")
    [ "$PROJECT_ACCESS" = "null" ] && PROJECT_ACCESS="acl"
    if [ "$PROJECT_ACCESS" != "acl" ] && [ "$PROJECT_ACCESS" != "copy" ] && [ "$PROJECT_ACCESS" != "clone" ]; then
        log_error "Unknown project_access: '$PROJECT_ACCESS' — valid values: acl, copy, clone"
        exit 1
    fi

    echo "  project_paths:"
    echo "$PROJECT_PATHS" | while IFS= read -r p; do [ -n "$p" ] && echo "    - $p"; done
    echo "  project_access: $PROJECT_ACCESS"
    echo "  docker_access:  $_DOCKER_ACCESS"
    echo ""

    WORKSPACE_DIR="$AGENT_HOME/workspace"
    mkdir -p "$WORKSPACE_DIR"

    if [ "$PROJECT_ACCESS" = "copy" ]; then
        # ── copy mode: project files are copied into dev-bot's own home ──────────
        # dev-bot owns its copy entirely — no ACLs granted on source paths,
        # no traverse grants on parent directories.
        log_info "Copying project_paths into $WORKSPACE_DIR (project_access: copy)..."
        while IFS= read -r path; do
            [ -z "$path" ] && continue
            if [ ! -d "$path" ]; then
                log_error "  project_path does not exist: $path"
                exit 1
            fi
            _dest="$WORKSPACE_DIR/$(basename "$path")"
            if command -v rsync &>/dev/null; then
                # rsync (no --delete): updates changed/new files from source
                # without removing files the agent may have created.
                rsync -a "$path/" "$_dest/"
                log_info "  rsync: $path -> $_dest"
            else
                if [ ! -d "$_dest" ]; then
                    cp -a "$path" "$_dest"
                    log_info "  copy: $path -> $_dest"
                else
                    cp -au "$path/." "$_dest/"
                    log_info "  update: $path -> $_dest"
                fi
            fi
            chown -R "$AGENT_USER:$AGENT_USER" "$_dest"
        done <<< "$PROJECT_PATHS"
        log_info "  dev-bot owns all workspace files — source paths are untouched"

    elif [ "$PROJECT_ACCESS" = "clone" ]; then
        # ── clone mode: repos are cloned fresh from GitHub into dev-bot's home ───
        # dev-bot owns all files from the start; no dependency on host source paths.
        # Requires github_repo to be set on each project_path entry.
        # On re-run, existing clones are left untouched (not re-cloned).
        log_info "Cloning project_paths from GitHub (project_access: clone)..."

        # Deploy keys must be set up before cloning.
        if [ "$GITHUB_REPOS" = "[]" ] || [ -z "$GITHUB_REPOS" ]; then
            log_error "  project_access: clone requires github_repo on every project_path entry"
            exit 1
        fi

        # Keys are uploaded by setup.sh from the operator machine (source of truth).
        # Fall back to generating locally only if running workspace_up.sh directly
        # (not via the remote setup flow).
        UPLOADED_KEYS_DIR="$SCRIPT_DIR/../../deploy_keys"
        if [ -d "$UPLOADED_KEYS_DIR" ]; then
            log_info "  Using pre-uploaded deploy keys from $UPLOADED_KEYS_DIR"
            DEPLOY_KEYS_BASE="$UPLOADED_KEYS_DIR"
        else
            log_info "  No pre-uploaded keys found — generating locally..."
            bash "$SCRIPT_DIR/../ssh_key/deploy_key_add.sh" "$HOST_NAME"
            DEPLOY_KEYS_BASE="/var/lib/openclaw/deploy_keys/${HOST_NAME}"
        fi

        AGENT_SSH_DIR="$AGENT_HOME/.ssh"
        DEPLOY_KEYS_DEST="$AGENT_SSH_DIR/deploy_keys"
        mkdir -p "$DEPLOY_KEYS_DEST"
        chmod 700 "$AGENT_SSH_DIR" "$DEPLOY_KEYS_DEST"

        # Install deploy keys and SSH config so git can authenticate.
        while IFS= read -r entry; do
            SLUG=$(echo "$entry" | jq -r '.slug')
            SRC_DIR="$DEPLOY_KEYS_BASE/$SLUG"
            DEST_DIR="$DEPLOY_KEYS_DEST/$SLUG"
            if [ ! -f "$SRC_DIR/id_ed25519" ]; then
                log_error "  Deploy key not found: $SRC_DIR/id_ed25519"
                log_error "  Run 'make setup HOST=$HOST_NAME' from the operator machine to upload keys."
                exit 1
            fi
            mkdir -p "$DEST_DIR"
            cp "$SRC_DIR/id_ed25519"     "$DEST_DIR/id_ed25519"
            cp "$SRC_DIR/id_ed25519.pub" "$DEST_DIR/id_ed25519.pub"
            chmod 600 "$DEST_DIR/id_ed25519"
            chmod 644 "$DEST_DIR/id_ed25519.pub"
        done < <(echo "$GITHUB_REPOS" | jq -c '.[]')
        chown -R "$AGENT_USER:$AGENT_USER" "$AGENT_SSH_DIR"

        # Write SSH config with per-repo Host aliases.
        SSH_CONFIG_FILE="$AGENT_SSH_DIR/config"
        touch "$SSH_CONFIG_FILE"
        sed -i '/# BEGIN openclaw github deploy keys/,/# END openclaw github deploy keys/d' "$SSH_CONFIG_FILE"
        {
            echo "# BEGIN openclaw github deploy keys"
            while IFS= read -r entry; do
                SLUG=$(echo "$entry" | jq -r '.slug')
                echo "Host github.com-${SLUG}"
                echo "  HostName github.com"
                echo "  User git"
                echo "  IdentitiesOnly yes"
                echo "  StrictHostKeyChecking yes"
                echo "  IdentityFile ~/.ssh/deploy_keys/${SLUG}/id_ed25519"
                echo ""
            done < <(echo "$GITHUB_REPOS" | jq -c '.[]')
            echo "# END openclaw github deploy keys"
        } >> "$SSH_CONFIG_FILE"
        chmod 600 "$SSH_CONFIG_FILE"
        chown "$AGENT_USER:$AGENT_USER" "$SSH_CONFIG_FILE"

        # Pre-populate github.com host keys.
        KNOWN_HOSTS_FILE="$AGENT_SSH_DIR/known_hosts"
        touch "$KNOWN_HOSTS_FILE"
        if ! grep -q "^github.com " "$KNOWN_HOSTS_FILE" 2>/dev/null; then
            ssh-keyscan -t rsa,ecdsa,ed25519 github.com 2>/dev/null >> "$KNOWN_HOSTS_FILE" || true
        fi
        chmod 644 "$KNOWN_HOSTS_FILE"
        chown "$AGENT_USER:$AGENT_USER" "$KNOWN_HOSTS_FILE"

        # Ensure dev-bot owns the workspace dir before cloning into it.
        chown "$AGENT_USER:$AGENT_USER" "$WORKSPACE_DIR"

        # Configure git insteadOf rewrites and clone each repo.
        while IFS= read -r entry; do
            SLUG=$(echo "$entry" | jq -r '.slug')
            REPO=$(echo "$entry" | jq -r '.repo')
            _dest="$WORKSPACE_DIR/$SLUG"

            su - "$AGENT_USER" -c "git config --global url.\"git@github.com-${SLUG}:${REPO}.git\".insteadOf \"git@github.com:${REPO}.git\""

            if [ -d "$_dest/.git" ]; then
                log_info "  $SLUG already cloned at $_dest — skipping"
            else
                rm -rf "$_dest"
                log_info "  Cloning $REPO -> $_dest ..."
                if su - "$AGENT_USER" -c "GIT_SSH_COMMAND='ssh -o StrictHostKeyChecking=yes' git clone \"git@github.com:${REPO}.git\" \"$_dest\""; then
                    log_info "  Cloned: $_dest"
                else
                    log_error "  Failed to clone $REPO — check deploy key is added to GitHub and has access"
                    exit 1
                fi
            fi
        done < <(echo "$GITHUB_REPOS" | jq -c '.[]')
        log_info "  dev-bot owns all cloned files — source paths on this host are not used"

    else
        # ── acl mode: grant access to source paths + symlink into workspace ──────
        log_info "Validating project_paths and granting ACLs..."
        grant_project_acls

        log_info "Creating workspace symlinks..."
        while IFS= read -r path; do
            [ -z "$path" ] && continue
            _link="$WORKSPACE_DIR/$(basename "$path")"
            if [ -L "$_link" ] && [ "$(readlink "$_link")" = "$path" ]; then
                log_info "  link OK: $_link"
            else
                ln -sfn "$path" "$_link"
                log_info "  link: $_link -> $path"
            fi
        done <<< "$PROJECT_PATHS"
    fi

    chown "$AGENT_USER:$AGENT_USER" "$WORKSPACE_DIR"

    # ── Deploy keys: install SSH config for github_repo paths ────────────────────
    # clone mode sets up keys inline during the clone step above; skip here.
    if [ "$PROJECT_ACCESS" != "clone" ] && [ "$GITHUB_REPOS" != "[]" ] && [ -n "$GITHUB_REPOS" ]; then
        echo ""
        log_info "Setting up GitHub deploy keys (restricted_key mode)..."

        # Keys are uploaded by setup.sh from the operator machine (source of truth).
        # Fall back to generating locally only if running workspace_up.sh directly.
        UPLOADED_KEYS_DIR="$SCRIPT_DIR/../../deploy_keys"
        if [ -d "$UPLOADED_KEYS_DIR" ]; then
            log_info "  Using pre-uploaded deploy keys from $UPLOADED_KEYS_DIR"
            DEPLOY_KEYS_BASE="$UPLOADED_KEYS_DIR"
        else
            log_info "  No pre-uploaded keys found — generating locally..."
            bash "$SCRIPT_DIR/../ssh_key/deploy_key_add.sh" "$HOST_NAME"
            DEPLOY_KEYS_BASE="/var/lib/openclaw/deploy_keys/${HOST_NAME}"
        fi

        AGENT_SSH_DIR="$AGENT_HOME/.ssh"
        DEPLOY_KEYS_DEST="$AGENT_SSH_DIR/deploy_keys"

        mkdir -p "$DEPLOY_KEYS_DEST"
        chmod 700 "$AGENT_SSH_DIR" "$DEPLOY_KEYS_DEST"

        # Copy deploy keys into dev-bot's .ssh directory (restricted_key has no container).
        while IFS= read -r entry; do
            SLUG=$(echo "$entry" | jq -r '.slug')
            SRC_DIR="$DEPLOY_KEYS_BASE/$SLUG"
            DEST_DIR="$DEPLOY_KEYS_DEST/$SLUG"
            if [ ! -f "$SRC_DIR/id_ed25519" ]; then
                log_error "  Deploy key not found: $SRC_DIR/id_ed25519"
                log_error "  Run 'make setup HOST=$HOST_NAME' from the operator machine to upload keys."
                exit 1
            fi
            mkdir -p "$DEST_DIR"
            cp "$SRC_DIR/id_ed25519"     "$DEST_DIR/id_ed25519"
            cp "$SRC_DIR/id_ed25519.pub" "$DEST_DIR/id_ed25519.pub"
            chmod 600 "$DEST_DIR/id_ed25519"
            chmod 644 "$DEST_DIR/id_ed25519.pub"
        done < <(echo "$GITHUB_REPOS" | jq -c '.[]')

        chown -R "$AGENT_USER:$AGENT_USER" "$AGENT_SSH_DIR"

        # Write SSH config for github.com using all deploy keys.
        SSH_CONFIG_FILE="$AGENT_SSH_DIR/config"
        touch "$SSH_CONFIG_FILE"
        # Remove any existing openclaw-managed github.com block.
        sed -i '/# BEGIN openclaw github deploy keys/,/# END openclaw github deploy keys/d' "$SSH_CONFIG_FILE"

        # Per-repo Host aliases: GitHub deploy keys are repo-scoped, so a shared
        # `Host github.com` block with multiple IdentityFiles causes GitHub to
        # reject operations when SSH offers the wrong repo's key first.
        {
            echo "# BEGIN openclaw github deploy keys"
            while IFS= read -r entry; do
                SLUG=$(echo "$entry" | jq -r '.slug')
                echo "Host github.com-${SLUG}"
                echo "  HostName github.com"
                echo "  User git"
                echo "  IdentitiesOnly yes"
                echo "  StrictHostKeyChecking yes"
                echo "  IdentityFile ~/.ssh/deploy_keys/${SLUG}/id_ed25519"
                echo ""
            done < <(echo "$GITHUB_REPOS" | jq -c '.[]')
            echo "# END openclaw github deploy keys"
        } >> "$SSH_CONFIG_FILE"

        chmod 600 "$SSH_CONFIG_FILE"
        chown "$AGENT_USER:$AGENT_USER" "$SSH_CONFIG_FILE"
        log_info "  SSH config written for GitHub deploy keys"

        # Pre-populate github.com host keys in known_hosts so StrictHostKeyChecking
        # doesn't block the agent's first git operation.
        KNOWN_HOSTS_FILE="$AGENT_SSH_DIR/known_hosts"
        touch "$KNOWN_HOSTS_FILE"
        if ! grep -q "^github.com " "$KNOWN_HOSTS_FILE" 2>/dev/null; then
            if ssh-keyscan -t rsa,ecdsa,ed25519 github.com 2>/dev/null >> "$KNOWN_HOSTS_FILE"; then
                log_info "  github.com host keys added to known_hosts"
            else
                log_warn "  ssh-keyscan github.com failed — agent may need to populate known_hosts manually"
            fi
        fi
        chmod 644 "$KNOWN_HOSTS_FILE"
        chown "$AGENT_USER:$AGENT_USER" "$KNOWN_HOSTS_FILE"

        # Configure git url.insteadOf rewrites so `git@github.com:owner/repo.git`
        # remotes are auto-rewritten to the per-repo Host alias.
        su - "$AGENT_USER" -c "git config --global --get-regexp '^url\\.git@github\\.com-.*\\.insteadof$' 2>/dev/null | awk '{print \$1}' | sed 's/\\.insteadof\$//' | sort -u | while read section; do git config --global --remove-section \"\$section\" 2>/dev/null || true; done" || true
        while IFS= read -r entry; do
            SLUG=$(echo "$entry" | jq -r '.slug')
            REPO=$(echo "$entry" | jq -r '.repo')
            su - "$AGENT_USER" -c "git config --global url.\"git@github.com-${SLUG}:${REPO}.git\".insteadOf \"git@github.com:${REPO}.git\""
        done < <(echo "$GITHUB_REPOS" | jq -c '.[]')
        log_info "  git insteadOf rewrites configured for ${AGENT_USER}"
    fi

    if [ "$_DOCKER_ACCESS" = "true" ]; then
        echo ""
        log_info "Setting up Docker proxy (docker_access: true)..."

        # Ensure Docker Compose plugin is present
        if ! docker compose version &>/dev/null 2>&1; then
            log_info "  Installing docker-compose-plugin..."
            if command -v apt-get &>/dev/null; then
                apt-get install -y docker-compose-plugin 2>/dev/null \
                    && log_info "  docker-compose-plugin installed" \
                    || log_warn "  Could not install docker-compose-plugin — install manually: apt install docker-compose-plugin"
            else
                log_warn "  apt-get not available — install docker compose plugin manually"
            fi
        else
            log_info "  Docker Compose: $(docker compose version --short 2>/dev/null || echo 'present')"
        fi

        # Locate system Docker socket (dev-bot never touches this directly)
        UPSTREAM_DOCKER_SOCK="/var/run/docker.sock"
        if [ ! -S "$UPSTREAM_DOCKER_SOCK" ]; then
            log_error "  Docker socket not found at $UPSTREAM_DOCKER_SOCK"
            log_error "  Ensure Docker is installed and running on this host."
            exit 1
        fi

        # Proxy socket dir: directory permissions (700, owned by dev-bot) restrict
        # access to dev-bot + root only, regardless of the socket's own mode.
        PROXY_DIR="/run/openclaw"
        mkdir -p "$PROXY_DIR"
        chown "$AGENT_USER:$AGENT_USER" "$PROXY_DIR"
        chmod 700 "$PROXY_DIR"

        PROXY_SOCKET_PATH="$PROXY_DIR/docker-proxy-${HOST_NAME}.sock"

        # Install proxy binary
        install -m 0755 "$SCRIPT_DIR/docker_proxy.py" /usr/local/bin/openclaw-docker-proxy

        # Stop any existing proxy for this host
        pkill -f "openclaw-docker-proxy.*docker-proxy-${HOST_NAME}" 2>/dev/null || true
        sleep 0.5
        rm -f "$PROXY_SOCKET_PATH"

        # Build proxy invocation with safely quoted paths.
        # - copy: projects live at $WORKSPACE_DIR/<basename>
        # - clone: projects live at $WORKSPACE_DIR/<slug> (owner-repo)
        # - acl:   source paths themselves are what dev-bot operates on
        PROXY_CMD="python3 /usr/local/bin/openclaw-docker-proxy"
        PROXY_CMD="$PROXY_CMD $(printf '%q' "$PROXY_SOCKET_PATH")"
        PROXY_CMD="$PROXY_CMD $(printf '%q' "$UPSTREAM_DOCKER_SOCK")"
        PROXY_ALLOWED_DISPLAY=""
        if [ "$PROJECT_ACCESS" = "clone" ]; then
            while IFS= read -r entry; do
                SLUG=$(echo "$entry" | jq -r '.slug')
                _effective="$WORKSPACE_DIR/$SLUG"
                PROXY_CMD="$PROXY_CMD $(printf '%q' "$_effective")"
                PROXY_ALLOWED_DISPLAY="$PROXY_ALLOWED_DISPLAY $_effective"
            done < <(echo "$GITHUB_REPOS" | jq -c '.[]')
        else
            while IFS= read -r _p; do
                [ -z "$_p" ] && continue
                if [ "$PROJECT_ACCESS" = "copy" ]; then
                    _effective="$WORKSPACE_DIR/$(basename "$_p")"
                else
                    _effective="$_p"
                fi
                PROXY_CMD="$PROXY_CMD $(printf '%q' "$_effective")"
                PROXY_ALLOWED_DISPLAY="$PROXY_ALLOWED_DISPLAY $_effective"
            done <<< "$PROJECT_PATHS"
        fi

        # Proxy runs as root — only root has access to the system Docker socket.
        # The directory permissions above ensure dev-bot is the only non-root
        # user that can connect to the proxy socket.
        nohup bash -c "$PROXY_CMD" </dev/null >/dev/null 2>&1 &

        # Wait up to 10 s for the proxy socket to appear
        for _ in $(seq 1 20); do
            [ -S "$PROXY_SOCKET_PATH" ] && break
            sleep 0.5
        done
        if [ ! -S "$PROXY_SOCKET_PATH" ]; then
            log_error "  Docker proxy failed to start."
            log_error "  Check $PROXY_DIR/docker-proxy.log"
            exit 1
        fi

        log_info "  Proxy socket : $PROXY_SOCKET_PATH"
        log_info "  Allowed paths:${PROXY_ALLOWED_DISPLAY}"

        # Persist DOCKER_HOST in dev-bot's shell init files so every SSH session
        # picks it up without any extra configuration. Ubuntu's default .bashrc
        # has an early `return` for non-interactive shells, so `ssh host cmd`
        # sessions (which the agent uses) never reach an appended export. We
        # prepend to .bashrc to run before that guard, and also write .profile
        # for login shells.
        DOCKER_HOST_LINE="export DOCKER_HOST=unix://${PROXY_SOCKET_PATH} # openclaw-docker-proxy"
        for _rc in "$AGENT_HOME/.bashrc" "$AGENT_HOME/.profile"; do
            touch "$_rc"
            sed -i '/# openclaw-docker-proxy/d' "$_rc"
        done
        # Prepend to .bashrc (runs before the interactive-shell guard).
        printf '%s\n%s' "$DOCKER_HOST_LINE" "$(cat "$AGENT_HOME/.bashrc")" > "$AGENT_HOME/.bashrc"
        # Append to .profile (no guard, order doesn't matter).
        printf '%s\n' "$DOCKER_HOST_LINE" >> "$AGENT_HOME/.profile"
        chown "$AGENT_USER:$AGENT_USER" \
            "$AGENT_HOME/.bashrc" "$AGENT_HOME/.profile" 2>/dev/null || true
        log_info "  DOCKER_HOST written to $AGENT_USER .bashrc (prepended) and .profile"
        log_warn "  Proxy is not persistent — re-run 'make setup HOST=$HOST_NAME' after host reboot"
    fi

    echo ""
    log_info "=== restricted_key setup complete for '$HOST_NAME' ==="
    log_info "Install the SSH key next: make key-add HOST=$HOST_NAME"
    exit 0
fi

FORWARD_PORTS=$(jq -r --arg name "$HOST_NAME" \
    '.ssh_hosts[] | select(.name == $name) | .forward_ports // [] | .[] | tostring' \
    "$CONFIG_JSON" | tr '\n' ' ' | xargs || true)

DOCKER_ACCESS=$(jq -r --arg name "$HOST_NAME" \
    '.ssh_hosts[] | select(.name == $name) | .docker_access // false' \
    "$CONFIG_JSON")
[ "$DOCKER_ACCESS" = "null" ] && DOCKER_ACCESS="false"

EGRESS_FILTER=$(jq -r --arg name "$HOST_NAME" \
    '.ssh_hosts[] | select(.name == $name) | .egress_filter // false' \
    "$CONFIG_JSON")
[ "$EGRESS_FILTER" = "null" ] && EGRESS_FILTER="false"

WORKSPACE_IMAGE="${WORKSPACE_IMAGE:-agents-workspace:latest}"
CONTAINER_NAME="workspace-${HOST_NAME}"

echo "=== Workspace setup for '$HOST_NAME' ==="
echo "  User:         $AGENT_USER"
echo "  Image:        $WORKSPACE_IMAGE"
echo "  Container:    $CONTAINER_NAME"
echo "  project_paths:"
echo "$PROJECT_PATHS" | while IFS= read -r p; do [ -n "$p" ] && echo "    - $p"; done
[ -n "$FORWARD_PORTS" ] && echo "  forward_ports: $FORWARD_PORTS" || echo "  forward_ports: (none)"
echo "  docker_access: $DOCKER_ACCESS"
echo "  egress_filter: $EGRESS_FILTER"
if [ "$GITHUB_REPOS" != "[]" ] && [ -n "$GITHUB_REPOS" ]; then
    echo "  github_repos:"
    echo "$GITHUB_REPOS" | jq -r '.[] | "    - \(.repo) (\(if .write then "read-write" else "read-only" end))"'
fi
echo ""

# ── 0. Generate GitHub deploy keys (if any project_paths declare github_repo) ──
if [ "$GITHUB_REPOS" != "[]" ] && [ -n "$GITHUB_REPOS" ]; then
    log_info "[0/8] Generating GitHub deploy keys..."
    bash "$SCRIPT_DIR/../ssh_key/deploy_key_add.sh" "$HOST_NAME"
    echo ""
fi

# ── 1. Ensure AGENT_USER exists on host ────────────────────────────────────────
log_info "[1/7] Ensuring $AGENT_USER exists..."
if ! id "$AGENT_USER" &>/dev/null; then
    useradd -m -s /bin/bash "$AGENT_USER"
    log_info "  Created $AGENT_USER"
else
    log_info "  Already exists"
fi
AGENT_UID=$(id -u "$AGENT_USER")
AGENT_GID=$(id -g "$AGENT_USER")
AGENT_HOME=$(eval echo "~$AGENT_USER")

# ── 2. Validate project_paths and grant access via ACL ────────────────────────
log_info "[2/7] Validating project_paths..."
grant_project_acls

# ── 3. Install rootless Docker for AGENT_USER ──────────────────────────────────
log_info "[3/7] Installing/starting rootless Docker..."
bash "$SCRIPT_DIR/install_rootless_docker.sh"

DOCKER_SOCKET_PATH="/run/user/$AGENT_UID/docker.sock"
if [ ! -S "$DOCKER_SOCKET_PATH" ]; then
    log_error "Rootless Docker socket not found at $DOCKER_SOCKET_PATH"
    exit 1
fi

_docker() { su - "$AGENT_USER" -c "DOCKER_HOST=unix://$DOCKER_SOCKET_PATH PATH=\$HOME/bin:\$PATH docker $*"; }

# ── 4. Build workspace image (if not present) ──────────────────────────────────
log_info "[4/7] Ensuring workspace image is available..."
if ! _docker image inspect "$WORKSPACE_IMAGE" &>/dev/null; then
    log_info "  Image $WORKSPACE_IMAGE not found; building from agents/workspace/Dockerfile"
    WORKSPACE_CTX="$PROJECT_ROOT/agents/workspace"
    if [ ! -f "$WORKSPACE_CTX/Dockerfile" ]; then
        log_error "  agents/workspace/Dockerfile not found at $WORKSPACE_CTX"
        exit 1
    fi
    # Copy build context to a location dev-bot can read
    BUILD_TMP="/tmp/agents-workspace-build-$$"
    cp -r "$WORKSPACE_CTX" "$BUILD_TMP"
    chown -R "$AGENT_USER:$AGENT_USER" "$BUILD_TMP"
    _docker build \
        --build-arg "DEV_BOT_UID=$AGENT_UID" \
        --build-arg "DEV_BOT_GID=$AGENT_GID" \
        -t "$WORKSPACE_IMAGE" \
        "$BUILD_TMP"
    rm -rf "$BUILD_TMP"
    log_info "  Built $WORKSPACE_IMAGE"
else
    log_info "  Image already present"
fi

# ── 5. Start Docker socket proxy (docker_access only) ─────────────────────────
if [ "$DOCKER_ACCESS" = "true" ]; then
    log_info "[5/8] Starting Docker socket proxy..."

    PROXY_SOCKET_PATH="/run/user/$AGENT_UID/docker-proxy.sock"

    # Install proxy binary to a fixed path so it persists across su sessions.
    install -m 0755 "$SCRIPT_DIR/docker_proxy.py" /usr/local/bin/openclaw-docker-proxy

    # Stop any existing proxy on this socket before (re)starting.
    pkill -u "$AGENT_USER" -f 'openclaw-docker-proxy' 2>/dev/null || true
    sleep 0.5
    rm -f "$PROXY_SOCKET_PATH"

    # Build the launch command with properly shell-quoted paths.
    PROXY_CMD="python3 /usr/local/bin/openclaw-docker-proxy"
    PROXY_CMD="$PROXY_CMD $(printf '%q' "$PROXY_SOCKET_PATH")"
    PROXY_CMD="$PROXY_CMD $(printf '%q' "$DOCKER_SOCKET_PATH")"
    while IFS= read -r _p; do
        [ -z "$_p" ] && continue
        PROXY_CMD="$PROXY_CMD $(printf '%q' "$_p")"
    done <<< "$PROJECT_PATHS"

    su - "$AGENT_USER" -c \
        "nohup $PROXY_CMD </dev/null >/dev/null 2>&1 &"

    # Wait up to 10 s for the proxy socket to appear.
    for _ in $(seq 1 20); do
        [ -S "$PROXY_SOCKET_PATH" ] && break
        sleep 0.5
    done
    if [ ! -S "$PROXY_SOCKET_PATH" ]; then
        log_error "Docker proxy failed to start. Check $(dirname "$PROXY_SOCKET_PATH")/docker-proxy.log"
        exit 1
    fi
    log_info "  Proxy socket : $PROXY_SOCKET_PATH"
    log_info "  Allowed paths: $(echo "$PROJECT_PATHS" | tr '\n' ' ')"
else
    log_info "[5/8] Skipping Docker proxy (docker_access is false)"
fi

# ── 6. (Re)create the workspace container ──────────────────────────────────────
log_info "[6/8] Running workspace container..."

# Stop/remove any existing container with the same name so changes to
# project_paths / forward_ports / docker_access take effect on re-run.
if _docker inspect --type=container "$CONTAINER_NAME" &>/dev/null; then
    log_info "  Existing container found — recreating"
    _docker rm -f "$CONTAINER_NAME" >/dev/null
fi

# Build docker run arguments
RUN_ARGS=(
    run -d
    --name "$CONTAINER_NAME"
    --restart=unless-stopped
    --cap-drop=ALL
    --security-opt no-new-privileges:true
    --user "$AGENT_UID:$AGENT_GID"
)

# Bind-mount each project_path at ~/workspace/<basename>.
while IFS= read -r path; do
    [ -z "$path" ] && continue
    RUN_ARGS+=(-v "$path:/home/dev-bot/workspace/$(basename "$path"):rw")
done <<< "$PROJECT_PATHS"

# Publish forward_ports to host localhost
for port in $FORWARD_PORTS; do
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        log_error "Invalid port in forward_ports: '$port'"
        exit 1
    fi
    RUN_ARGS+=(-p "127.0.0.1:$port:$port")
done

# Docker-in-Docker: bind-mount the filtering proxy socket (never the real socket).
# The proxy enforces project_paths allowlist and blocks --privileged / network=host.
if [ "$DOCKER_ACCESS" = "true" ]; then
    PROXY_SOCKET_PATH="/run/user/$AGENT_UID/docker-proxy.sock"
    RUN_ARGS+=(-v "$PROXY_SOCKET_PATH:/var/run/docker.sock")
    RUN_ARGS+=(-e "DOCKER_HOST=unix:///var/run/docker.sock")
    log_info "  docker_access: bind-mounting filtered proxy socket (not the real daemon socket)"
fi

# GitHub deploy keys: bind-mount host key store read-only into container.
DEPLOY_KEYS_BASE="/var/lib/openclaw/deploy_keys/${HOST_NAME}"
if [ "$GITHUB_REPOS" != "[]" ] && [ -n "$GITHUB_REPOS" ] && [ -d "$DEPLOY_KEYS_BASE" ]; then
    RUN_ARGS+=(-v "$DEPLOY_KEYS_BASE:/home/dev-bot/.ssh/deploy_keys:ro")
    log_info "  deploy_keys: bind-mounting $DEPLOY_KEYS_BASE read-only"
fi

RUN_ARGS+=("$WORKSPACE_IMAGE" sleep infinity)

# Pass the arguments through su -> docker. Quote each arg safely for the shell.
_quoted_args=$(printf ' %q' "${RUN_ARGS[@]}")
su - "$AGENT_USER" -c "DOCKER_HOST=unix://$DOCKER_SOCKET_PATH PATH=\$HOME/bin:\$PATH docker$_quoted_args" >/dev/null
log_info "  Container '$CONTAINER_NAME' running"

# Write SSH config for GitHub deploy keys inside the container.
if [ "$GITHUB_REPOS" != "[]" ] && [ -n "$GITHUB_REPOS" ] && [ -d "$DEPLOY_KEYS_BASE" ]; then
    _docker_exec() { su - "$AGENT_USER" -c "DOCKER_HOST=unix://$DOCKER_SOCKET_PATH PATH=\$HOME/bin:\$PATH docker exec $*"; }
    _docker_exec "$CONTAINER_NAME" mkdir -p /home/dev-bot/.ssh
    _docker_exec "$CONTAINER_NAME" chmod 700 /home/dev-bot/.ssh

    # Per-repo Host aliases: deploy keys are repo-scoped, so a shared
    # `Host github.com` block breaks multi-repo access (see restricted_key branch).
    SSH_CONFIG_CONTENT="# BEGIN openclaw github deploy keys"
    while IFS= read -r entry; do
        SLUG=$(echo "$entry" | jq -r '.slug')
        SSH_CONFIG_CONTENT="$SSH_CONFIG_CONTENT
Host github.com-${SLUG}
  HostName github.com
  User git
  IdentitiesOnly yes
  StrictHostKeyChecking yes
  IdentityFile /home/dev-bot/.ssh/deploy_keys/${SLUG}/id_ed25519
"
    done < <(echo "$GITHUB_REPOS" | jq -c '.[]')
    SSH_CONFIG_CONTENT="$SSH_CONFIG_CONTENT
# END openclaw github deploy keys"

    echo "$SSH_CONFIG_CONTENT" | \
        su - "$AGENT_USER" -c "DOCKER_HOST=unix://$DOCKER_SOCKET_PATH PATH=\$HOME/bin:\$PATH docker exec -i $CONTAINER_NAME tee /home/dev-bot/.ssh/config" >/dev/null
    _docker_exec "$CONTAINER_NAME" chmod 600 /home/dev-bot/.ssh/config
    log_info "  SSH config written inside container for GitHub deploy keys"

    # Pre-populate github.com host keys in known_hosts so StrictHostKeyChecking
    # doesn't block the agent's first git operation. Scan from the host (where
    # DNS/egress to github.com is available) and pipe into the container.
    if KEYSCAN_OUTPUT=$(ssh-keyscan -t rsa,ecdsa,ed25519 github.com 2>/dev/null) && [ -n "$KEYSCAN_OUTPUT" ]; then
        echo "$KEYSCAN_OUTPUT" | \
            su - "$AGENT_USER" -c "DOCKER_HOST=unix://$DOCKER_SOCKET_PATH PATH=\$HOME/bin:\$PATH docker exec -i $CONTAINER_NAME tee -a /home/dev-bot/.ssh/known_hosts" >/dev/null
        _docker_exec "$CONTAINER_NAME" chmod 644 /home/dev-bot/.ssh/known_hosts
        log_info "  github.com host keys added to container's known_hosts"
    else
        log_warn "  ssh-keyscan github.com failed — agent may need to populate known_hosts manually"
    fi

    # Configure git url.insteadOf rewrites inside the container so
    # `git@github.com:owner/repo.git` remotes are auto-rewritten.
    while IFS= read -r entry; do
        SLUG=$(echo "$entry" | jq -r '.slug')
        REPO=$(echo "$entry" | jq -r '.repo')
        _docker_exec "$CONTAINER_NAME" git config --global "url.git@github.com-${SLUG}:${REPO}.git.insteadOf" "git@github.com:${REPO}.git"
    done < <(echo "$GITHUB_REPOS" | jq -c '.[]')
    log_info "  git insteadOf rewrites configured inside container"
fi

# ── 6. Install session-entry ForceCommand script ───────────────────────────────
log_info "[7/8] Installing openclaw-session-entry..."
install -m 0755 "$SCRIPT_DIR/session_entry.sh" /usr/local/bin/openclaw-session-entry
log_info "  /usr/local/bin/openclaw-session-entry installed"

# ── 7. Configure sshd Match block (PermitOpen only — no ChrootDirectory) ───────
log_info "[8/8] Configuring sshd Match block..."
if [ -n "$FORWARD_PORTS" ]; then
    PERMIT_OPEN_LINE=""
    for port in $FORWARD_PORTS; do
        PERMIT_OPEN_LINE="${PERMIT_OPEN_LINE} localhost:${port}"
    done
    PERMIT_OPEN_LINE="${PERMIT_OPEN_LINE# }"
    TCP_FORWARDING_LINE="AllowTcpForwarding local"
    PERMIT_OPEN_CONFIG="    PermitOpen ${PERMIT_OPEN_LINE}"
else
    TCP_FORWARDING_LINE="AllowTcpForwarding no"
    PERMIT_OPEN_CONFIG=""
fi

SSHD_CONFIG_BLOCK="# BEGIN Dev-Agent Workspace Configuration
Match User $AGENT_USER
    X11Forwarding no
    ${TCP_FORWARDING_LINE}
    PermitTunnel no
    ClientAliveInterval 300
    ClientAliveCountMax 3
    MaxSessions 3
${PERMIT_OPEN_CONFIG}
# END Dev-Agent Workspace Configuration"

# Replace existing block so re-runs pick up changes.
for marker in "Dev-Agent Workspace Configuration"; do
    if grep -q "# BEGIN $marker" /etc/ssh/sshd_config 2>/dev/null; then
        sed -i "/# BEGIN $marker/,/# END $marker/d" /etc/ssh/sshd_config
    fi
done
printf '\n%s\n' "$SSHD_CONFIG_BLOCK" >> /etc/ssh/sshd_config
log_info "  sshd_config updated (reload required)"

# ── 8. Optional: apply UID-keyed egress filter ─────────────────────────────────
if [ "$EGRESS_FILTER" = "true" ]; then
    echo ""
    log_info "Applying egress filter..."
    bash "$SCRIPT_DIR/egress_filter.sh" "$HOST_NAME"
fi

echo ""
log_info "=== Workspace ready for '$HOST_NAME' ==="
echo "  Container: $CONTAINER_NAME"
echo "  Socket:    $DOCKER_SOCKET_PATH"
echo ""
echo "Next steps:"
echo "  1. make key-add HOST=$HOST_NAME   (install ForceCommand authorized_keys)"
echo "  2. systemctl reload sshd          (apply sshd Match block)"
echo "  3. make test HOST=$HOST_NAME      (verify)"
