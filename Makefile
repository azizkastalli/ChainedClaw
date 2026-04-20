# OpenClaw Makefile
# Simplified interface for container management and cleanup
#
# Usage:
#   make uninstall        - Full uninstallation
#   make help             - Show all available targets
#
# Local host targets (require HOST parameter):
#   make chroot HOST=name       - Set up chroot for a local host
#   make chroot-clean HOST=name - Tear down chroot for a local host
#   make key-add HOST=name      - Install SSH key to host chroot
#   make key-remove HOST=name   - Remove SSH key from host chroot
#   make sync HOST=name         - Re-sync SSH key (alias for key-add)
#   make test HOST=name         - Test SSH connection to host
#
# Remote host targets (require HOST, REMOTE_KEY; hostname/port from config.json):
#   make remote-setup HOST=name REMOTE_KEY=/path/to/key [REMOTE_USER=user]
#   make remote-clean HOST=name REMOTE_KEY=/path/to/key [REMOTE_USER=user]

.PHONY: help uninstall config wizard keys auth build up down restart logs status \
        preflight setup chroot chroot-clean key-add key-remove sync \
        firewall firewall-flush remote-setup remote-clean test clean purge purge-data \
        security-check

# Default target
.DEFAULT_GOAL := help

# Configuration
SCRIPTS_DIR := scripts
CONTAINER_NAME ?= $(shell grep -E '^AGENT_CONTAINER_NAME=' .env 2>/dev/null | cut -d= -f2 | sed 's/#.*//' | tr -d ' ')
CONTAINER_NAME := $(or $(CONTAINER_NAME),agent-dev)
# Agent user inside the running container (read from container env at make-time)
AGENT_EXEC_USER := $(shell docker inspect $(CONTAINER_NAME) --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | grep '^AGENT_USER=' | cut -d= -f2 | tr -d ' ')
AGENT_EXEC_USER := $(or $(AGENT_EXEC_USER),root)

# ------------------------------------------------------------------------------
# Help
# ------------------------------------------------------------------------------

help: ## Show this help message
	@echo "OpenClaw - AI agent platform with SSH bridge"
	@echo ""
	@echo "Usage: make [target] [HOST=name]"
	@echo ""
	@echo "Installation:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Host-specific targets (require HOST=name):"
	@echo "  setup             Full host setup: chroot + key + sshd reload (recommended)"
	@echo "  chroot            Set up chroot jail for HOST (step 1 of setup)"
	@echo "  chroot-clean      Tear down chroot for HOST"
	@echo "  key-add           Install SSH key to HOST chroot (step 2 of setup)"
	@echo "  key-remove        Remove SSH key from HOST chroot"
	@echo "  sync              Re-sync SSH key to HOST (alias for key-add)"
	@echo "  test              Test SSH connection to HOST"
	@echo ""
	@echo "Remote host targets (hostname/port read from config.json):"
	@echo "  remote-setup      Copy files and set up chroot on a remote host"
	@echo "  remote-clean      Tear down chroot on a remote host and clean up"
	@echo ""
	@echo "Examples:"
	@echo "  make keys                       # Generate SSH keys"
	@echo "  make auth                       # Initialize dashboard credentials"
	@echo "  make up                         # Start containers"
	@echo "  make chroot HOST=my-host        # Set up chroot for local host"
	@echo "  make key-add HOST=my-host       # Install SSH key to local chroot"
	@echo "  make remote-setup HOST=my-host REMOTE_KEY=~/.ssh/id_rsa"
	@echo "  make test HOST=my-host          # Test SSH to my-host"
	@echo "  make logs                       # Show container logs"

# ------------------------------------------------------------------------------
# Installation
# ------------------------------------------------------------------------------

uninstall: ## Full uninstallation (keeps images, config)
	@echo "=== Uninstalling OpenClaw ==="
	sudo bash $(SCRIPTS_DIR)/uninstall.sh

wizard: ## Run the interactive setup wizard
	python3 wizard.py

config: ## Copy example config files if not exist
	@if [ ! -f .env ]; then \
		cp .env.example .env && echo "Created .env"; \
	fi
	@if [ ! -f config.json ]; then \
		cp config.example.json config.json && echo "Created config.json"; \
	fi

keys: ## Initialize SSH keys and data directories
	sudo bash $(SCRIPTS_DIR)/ssh_key/init_keys.sh

auth: ## Initialize dashboard authentication
	bash $(SCRIPTS_DIR)/nginx/init_htpasswd.sh

build: ## Build agent image (usage: make build AGENT=openclaw|claudecode|hermes)
ifndef AGENT
	@echo "Error: AGENT required. Usage: make build AGENT=openclaw|claudecode|hermes"
	@exit 1
endif
ifeq ($(filter $(AGENT),openclaw claudecode hermes),)
	@echo "Error: AGENT must be 'openclaw', 'claudecode', or 'hermes'"
	@exit 1
endif
  
	docker compose --profile $(AGENT) build

# ------------------------------------------------------------------------------
# Container Management
# ------------------------------------------------------------------------------

up: security-check ## Start an agent container + firewall (usage: make up AGENT=openclaw|claudecode|hermes)
ifndef AGENT
	@echo ""
	@echo "Error: AGENT is required."
	@echo ""
	@echo "  make up AGENT=openclaw       OpenClaw agent + nginx dashboard"
	@echo "  make up AGENT=claudecode     Claude Code agent (headless, internal firewall)"
	@echo "  make up AGENT=hermes         Hermes Agent (NousResearch, interactive CLI)"
	@echo ""
	@exit 1
endif
ifeq ($(filter $(AGENT),openclaw claudecode hermes),)
	@echo "Error: AGENT must be 'openclaw', 'claudecode', or 'hermes'"
	@exit 1
endif
  
	docker compose --profile $(AGENT) up -d
	@echo ""
	@echo "Applying firewall rules (requires sudo)..."
	sudo -E bash $(SCRIPTS_DIR)/firewall/setup_firewall.sh
	@echo ""
	@echo "Security layers active. Run 'make preflight' to verify all layers."

down: ## Stop running agent container
	docker compose --profile openclaw --profile claudecode --profile hermes down

restart: ## Restart agent container and re-apply firewall (usage: make restart AGENT=openclaw|claudecode|hermes)
ifndef AGENT
	@echo "Error: AGENT required. Usage: make restart AGENT=openclaw|claudecode|hermes"
	@exit 1
endif
ifeq ($(filter $(AGENT),openclaw claudecode hermes),)
	@echo "Error: AGENT must be 'openclaw', 'claudecode', or 'hermes'"
	@exit 1
endif
  
	docker compose --profile $(AGENT) restart
	@echo ""
	@echo "Re-applying firewall rules (requires sudo)..."
	sudo -E bash $(SCRIPTS_DIR)/firewall/setup_firewall.sh

shell: ## Open a shell inside the container as the agent user (with SSH_AUTH_SOCK)
	@SOCKET=$$(docker exec -u $(AGENT_EXEC_USER) $(CONTAINER_NAME) bash -c 'ls /tmp/ssh-*/agent.* 2>/dev/null | head -1'); \
	if [ -n "$$SOCKET" ]; then \
		echo "SSH agent socket: $$SOCKET"; \
		docker exec -it -u $(AGENT_EXEC_USER) -e SSH_AUTH_SOCK="$$SOCKET" $(CONTAINER_NAME) bash; \
	else \
		echo "Warning: No SSH agent socket found"; \
		docker exec -it -u $(AGENT_EXEC_USER) $(CONTAINER_NAME) bash; \
	fi

logs: ## Show container logs (follow mode)
	docker logs -f $(CONTAINER_NAME)

status: ## Show container status
	@docker compose ps

# ------------------------------------------------------------------------------
# Security
# ------------------------------------------------------------------------------

security-check: ## Verify seccomp profile and Docker capabilities support
	@if [ ! -f security/seccomp-agent.json ]; then \
		echo ""; \
		echo "ERROR: Seccomp profile not found at security/seccomp-agent.json"; \
		echo ""; \
		exit 1; \
	fi
	@if ! docker info --format '{{.SecurityOptions}}' 2>/dev/null | grep -q seccomp; then \
		echo ""; \
		echo "ERROR: Docker seccomp support not detected."; \
		echo "Seccomp is required for agent container security."; \
		echo ""; \
		exit 1; \
	fi
	@echo "Security prerequisites OK (seccomp profile found, Docker supports seccomp)."

preflight: ## Verify all security layers are active
	@echo ""
	@echo "=== OpenClaw Security Pre-flight ==="
	@echo ""
	@echo "[1/4] Seccomp profile ..........."
	@if [ -f security/seccomp-agent.json ]; then \
		echo "      OK - security/seccomp-agent.json present"; \
	else \
		echo "      FAIL - security/seccomp-agent.json missing"; \
		exit 1; \
	fi
	@echo ""
	@echo "[2/4] Firewall rules ..."
	@if sudo iptables -L FORWARD -n 2>/dev/null | grep -q "AGENT-DEV-FIREWALL"; then \
		echo "      OK - AGENT-DEV-FIREWALL rules are present"; \
	else \
		echo "      FAIL - no firewall rules found"; \
		echo "      Fix: make up  (firewall is now applied automatically)"; \
		exit 1; \
	fi
	@echo ""
	@echo "[3/4] Container status ..."
	@if docker ps --filter "name=$(CONTAINER_NAME)" --filter "status=running" 2>/dev/null | grep -q "$(CONTAINER_NAME)"; then \
		echo "      OK - container is running"; \
	else \
		echo "      FAIL - container is not running"; \
		echo "      Fix: make up"; \
		exit 1; \
	fi
	@echo ""
	@echo "[4/4] Container capabilities ..."
	@if docker inspect $(CONTAINER_NAME) --format '{{.HostConfig.CapAdd}}' 2>/dev/null | grep -q "NET_ADMIN"; then \
		echo "      OK - NET_ADMIN present (iptables rules)"; \
	else \
		echo "      WARN - NET_ADMIN not found (internal egress firewall may not work)"; \
	fi
	@if docker inspect $(CONTAINER_NAME) --format '{{.HostConfig.CapAdd}}' 2>/dev/null | grep -q "NET_RAW"; then \
		echo "      OK - NET_RAW present (raw socket support for iptables)"; \
	else \
		echo "      WARN - NET_RAW not found (iptables may not function correctly)"; \
	fi
	@if docker inspect $(CONTAINER_NAME) --format '{{.HostConfig.CapDrop}}' 2>/dev/null | grep -q "ALL"; then \
		echo "      OK - cap_drop: ALL (minimal capabilities)"; \
	else \
		echo "      WARN - cap_drop: ALL not set (container has more capabilities than needed)"; \
	fi
	@echo ""
	@echo "All security layers active."
	@echo "To verify per-host access: make test HOST=<name>"

# ------------------------------------------------------------------------------
# Chroot Management (requires HOST parameter)
# ------------------------------------------------------------------------------

setup: ## Full host setup in one step: chroot + SSH key + sshd reload (usage: make setup HOST=name)
ifndef HOST
	@echo "Error: HOST parameter required. Usage: make setup HOST=name"
	@exit 1
endif
	@echo "=== Setting up host: $(HOST) ==="
	sudo bash $(SCRIPTS_DIR)/chroot_jail/jail_set.sh $(HOST)
	sudo bash $(SCRIPTS_DIR)/ssh_key/add.sh $(HOST)
	sudo systemctl reload sshd
	@echo ""
	@echo "Host $(HOST) is ready. Verify with: make test HOST=$(HOST)"

chroot: ## Set up chroot jail for HOST (usage: make chroot HOST=name)
ifndef HOST
	@echo "Error: HOST parameter required. Usage: make chroot HOST=name"
	@exit 1
endif
	sudo bash $(SCRIPTS_DIR)/chroot_jail/jail_set.sh $(HOST)
	@echo "Reloading sshd..."
	sudo systemctl reload sshd

chroot-clean: ## Tear down chroot for HOST (usage: make chroot-clean HOST=name)
ifndef HOST
	@echo "Error: HOST parameter required. Usage: make chroot-clean HOST=name"
	@exit 1
endif
	sudo bash $(SCRIPTS_DIR)/chroot_jail/jail_break.sh $(HOST)
	@echo "Reloading sshd..."
	sudo systemctl reload sshd
	@echo ""
	@echo "NOTE: If you re-create the chroot, re-install the SSH key:"
	@echo "  make chroot HOST=$(HOST) && make key-add HOST=$(HOST)"

# ------------------------------------------------------------------------------
# Maintenance
# ------------------------------------------------------------------------------

key-add: ## Install SSH key to HOST (mode-aware: chroot or restricted_key)
ifndef HOST
	@echo "Error: HOST parameter required. Usage: make key-add HOST=name"
	@exit 1
endif
	sudo bash $(SCRIPTS_DIR)/ssh_key/add.sh $(HOST)
	sudo systemctl reload sshd 2>/dev/null || true

key-remove: ## Remove SSH key from HOST (mode-aware: chroot or restricted_key)
ifndef HOST
	@echo "Error: HOST parameter required. Usage: make key-remove HOST=name"
	@exit 1
endif
	sudo bash $(SCRIPTS_DIR)/ssh_key/remove.sh $(HOST)
	sudo systemctl reload sshd 2>/dev/null || true

sync: ## Re-sync SSH key to HOST (alias for key-add)
ifndef HOST
	@echo "Error: HOST parameter required. Usage: make sync HOST=name"
	@exit 1
endif
	sudo bash $(SCRIPTS_DIR)/ssh_key/add.sh $(HOST)
	sudo systemctl reload sshd 2>/dev/null || true

# ------------------------------------------------------------------------------
# Remote Host Management (requires HOST, REMOTE_IP, REMOTE_KEY parameters)
# ------------------------------------------------------------------------------

remote-setup: ## Set up chroot on a remote host (usage: make remote-setup HOST=name REMOTE_KEY=/path/to/key)
ifndef HOST
	@echo "Error: HOST required. Usage: make remote-setup HOST=name REMOTE_KEY=/path/to/key"
	@exit 1
endif
ifndef REMOTE_KEY
	@echo "Error: REMOTE_KEY required. Usage: make remote-setup HOST=name REMOTE_KEY=/path/to/key"
	@exit 1
endif
	bash $(SCRIPTS_DIR)/remote/setup.sh $(HOST) $(REMOTE_KEY) $(REMOTE_USER)

remote-clean: ## Tear down chroot on a remote host (usage: make remote-clean HOST=name REMOTE_KEY=/path/to/key)
ifndef HOST
	@echo "Error: HOST required. Usage: make remote-clean HOST=name REMOTE_KEY=/path/to/key"
	@exit 1
endif
ifndef REMOTE_KEY
	@echo "Error: REMOTE_KEY required. Usage: make remote-clean HOST=name REMOTE_KEY=/path/to/key"
	@exit 1
endif
	bash $(SCRIPTS_DIR)/remote/teardown.sh $(HOST) $(REMOTE_KEY) $(REMOTE_USER)

firewall: ## Set up firewall rules
	sudo -E bash $(SCRIPTS_DIR)/firewall/setup_firewall.sh

firewall-flush: ## Remove firewall rules
	sudo -E bash $(SCRIPTS_DIR)/firewall/setup_firewall.sh --flush

test: ## Test SSH connection to HOST
ifndef HOST
	@echo "Error: HOST parameter required. Usage: make test HOST=name"
	@exit 1
endif
	@echo "Testing SSH connection to $(HOST) (as $(AGENT_EXEC_USER))..."
	docker exec -i -u $(AGENT_EXEC_USER) $(CONTAINER_NAME) \
		bash -c 'SSH_AUTH_SOCK=$$(ls /tmp/ssh-*/agent.* 2>/dev/null | head -1); export SSH_AUTH_SOCK; ssh $(HOST) whoami'

# ------------------------------------------------------------------------------
# Cleanup
# ------------------------------------------------------------------------------

clean: ## Remove generated runtime files (htpasswd, tmp data)
	rm -rf .openclaw-data/tmp 2>/dev/null || true
	rm -f nginx/.htpasswd 2>/dev/null || true
	@echo "Runtime files removed"

purge-data: ## Remove agent data directories (WARNING: destructive)
	@echo ""
	@echo "=========================================="
	@echo "  WARNING: This will permanently delete all agent data!"
	@echo "=========================================="
	@echo ""
	@echo "This will remove:"
	@echo "  - .openclaw-data/    (OpenClaw config, workspaces, history)"
	@echo "  - .claudecode-data/  (Claude Code config, sessions)"
	@echo "  - .hermes-data/      (Hermes Agent config, sessions)"
	@echo ""
	@echo "This action cannot be undone!"
	@echo ""
	@read -p "Type 'yes' to confirm: " confirm && [ "$$confirm" = "yes" ] || exit 1
	@echo ""
	rm -rf .openclaw-data .claudecode-data .hermes-data
	@echo "Agent data directories removed."

purge: ## Full cleanup including config files and data (WARNING: destructive)
	@echo ""
	@echo "=========================================="
	@echo "  WARNING: This will remove ALL OpenClaw data!"
	@echo "=========================================="
	@echo ""
	@echo "This will remove:"
	@echo "  - Docker containers and chroots"
	@echo "  - SSH keys"
	@echo "  - Configuration files (.env, config.json)"
	@echo "  - Agent data directories (.openclaw-data, .claudecode-data, .hermes-data)"
	@echo ""
	@echo "This action cannot be undone!"
	@echo ""
	@read -p "Type 'yes' to confirm: " confirm && [ "$$confirm" = "yes" ] || exit 1
	$(MAKE) uninstall
	rm -f .env config.json
	rm -rf .openclaw-data .claudecode-data .hermes-data
	@echo ""
	@echo "Purge complete"
