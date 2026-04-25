#!/bin/bash
#
# Generate GitHub deploy keys for project_paths that declare a github_repo.
#
# Keys are stored at <project-root>/.ssh/deploy_keys/<host>/<owner-repo>/
# (operator machine is the source of truth). They are uploaded to the remote
# during setup, and bind-mounted read-only into the workspace container.
#
# Running this script is idempotent — existing keys are not regenerated.
# Runs as the regular user (no sudo); .ssh/ is gitignored.
#
# Usage: deploy_key_add.sh <host-name>
#
set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_key()   { echo -e "${CYAN}[KEY]${NC} $1"; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONFIG_JSON="$PROJECT_ROOT/config.json"

if [ -z "${1:-}" ]; then
    echo "Usage: $0 <host-name>"
    exit 1
fi
HOST_NAME="$1"

if ! command -v jq &>/dev/null; then
    log_error "jq is required. Install with: apt install jq"
    exit 1
fi

# Extract all project_paths entries that carry a github_repo field.
GITHUB_REPOS=$(jq -c --arg name "$HOST_NAME" \
    '[.ssh_hosts[] | select(.name == $name)
      | .project_paths[]
      | select(type == "object" and (.github_repo // "") != "")
      | {path: .path, repo: .github_repo, slug: (.github_repo | gsub("/"; "-")), write: (.github_write // false)}
     ]' \
    "$CONFIG_JSON" 2>/dev/null)

if [ -z "$GITHUB_REPOS" ] || [ "$GITHUB_REPOS" = "[]" ]; then
    log_warn "No project_paths with 'github_repo' found for host '$HOST_NAME' in config.json"
    log_warn "Add entries like: {\"path\": \"/your/project\", \"github_repo\": \"owner/repo\"}"
    exit 0
fi

KEYS_BASE="$PROJECT_ROOT/.ssh/deploy_keys/${HOST_NAME}"
mkdir -p "$KEYS_BASE"
chmod 700 "$KEYS_BASE"

NEEDS_ADDING=()

while IFS= read -r entry; do
    REPO=$(echo "$entry" | jq -r '.repo')
    SLUG=$(echo "$entry" | jq -r '.slug')
    PATH_="$(echo "$entry" | jq -r '.path')"
    WRITE=$(echo "$entry" | jq -r '.write')

    KEY_DIR="$KEYS_BASE/$SLUG"
    KEY_FILE="$KEY_DIR/id_ed25519"
    PUB_FILE="$KEY_DIR/id_ed25519.pub"

    mkdir -p "$KEY_DIR"
    chmod 700 "$KEY_DIR"

    if [ -f "$KEY_FILE" ]; then
        log_info "Key already exists for $REPO — skipping generation"
    else
        log_info "Generating deploy key for $REPO ..."
        ssh-keygen -t ed25519 \
            -C "${HOST_NAME}-${SLUG}" \
            -f "$KEY_FILE" \
            -N "" \
            -q
        chmod 600 "$KEY_FILE"
        chmod 644 "$PUB_FILE"
        log_info "  Generated: $KEY_FILE"
        NEEDS_ADDING+=("$REPO|$SLUG|$WRITE|$PUB_FILE")
    fi
done < <(echo "$GITHUB_REPOS" | jq -c '.[]')

echo ""
echo "=========================================="
echo "  Deploy keys ready for host '$HOST_NAME'"
echo "=========================================="
echo ""

# Always print all public keys so the operator can verify what's installed.
while IFS= read -r entry; do
    REPO=$(echo "$entry" | jq -r '.repo')
    SLUG=$(echo "$entry" | jq -r '.slug')
    WRITE=$(echo "$entry" | jq -r '.write')
    PUB_FILE="$KEYS_BASE/$SLUG/id_ed25519.pub"

    ACCESS="read-only"
    [ "$WRITE" = "true" ] && ACCESS="read-write"

    echo "  Repository : $REPO  ($ACCESS)"
    echo "  Public key :"
    echo ""
    cat "$PUB_FILE"
    echo ""
    echo "  Add at: https://github.com/$REPO/settings/keys/new"
    echo "  Title : ${HOST_NAME}-${SLUG}"
    [ "$WRITE" = "true" ] && echo "  Check : Allow write access" || echo "  Uncheck: Allow write access (read-only)"
    echo "------------------------------------------"
    echo ""
done < <(echo "$GITHUB_REPOS" | jq -c '.[]')

log_info "Keys stored at: $KEYS_BASE"
log_info "workspace_up.sh will bind-mount them read-only into the workspace container."
