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

.PHONY: help uninstall config keys auth up down restart logs status \
        preflight setup chroot chroot-clean key-add key-remove sync \
        firewall firewall-flush remote-setup remote-clean test clean purge

# Default target
.DEFAULT_GOAL := help

# Configuration
SCRIPTS_DIR := scripts
CONTAINER_NAME := openclaw

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
	@echo "  make remote-clean HOST=my-host REMOTE_KEY=~/.ssh/id_rsa"
	@echo "  make test HOST=my-host          # Test SSH to my-host"
	@echo "  make logs                       # Show container logs"

# ------------------------------------------------------------------------------
# Installation
# ------------------------------------------------------------------------------

sysbox-check: ## Verify Sysbox runtime is installed (required for DinD)
	@if ! docker info --format '{{range .Runtimes}}{{.Path}} {{end}}' 2>/dev/null | grep -q sysbox; then \
		echo ""; \
		echo "ERROR: Sysbox runtime not found."; \
		echo ""; \
		echo "OpenClaw uses Sysbox to run Docker-in-Docker securely (without privileged mode)."; \
		echo "Install Sysbox on Ubuntu/Debian:"; \
		echo ""; \
		echo "  VER=0.6.4"; \
		echo "  wget https://downloads.nestybox.com/sysbox/releases/v\$$VER/sysbox-ce_\$$VER-0.linux_amd64.deb"; \
		echo "  sudo apt-get install -y ./sysbox-ce_\$$VER-0.linux_amd64.deb"; \
		echo ""; \
		echo "After install, Docker automatically recognizes the sysbox-runc runtime."; \
		echo "See https://github.com/nestybox/sysbox for other distros and docs."; \
		echo ""; \
		exit 1; \
	fi
	@echo "Sysbox runtime found."

uninstall: ## Full uninstallation (keeps images, config)
	@echo "=== Uninstalling OpenClaw ==="
	sudo bash $(SCRIPTS_DIR)/uninstall.sh

config: ## Copy example config files if not exist
	@if [ ! -f .env ]; then \
		cp .env.example .env && echo "Created .env"; \
	fi
	@if [ ! -f config.json ]; then \
		cp config.example.json config.json && echo "Created config.json"; \
	fi

keys: ## Initialize SSH keys
	sudo bash $(SCRIPTS_DIR)/ssh_key/init_keys.sh

auth: ## Initialize dashboard authentication
	bash $(SCRIPTS_DIR)/nginx/init_htpasswd.sh

# ------------------------------------------------------------------------------
# Container Management
# ------------------------------------------------------------------------------

up: sysbox-check ## Start containers and apply firewall rules (mandatory together)
	docker compose up -d
	@echo ""
	@echo "Applying firewall rules (requires sudo)..."
	sudo bash $(SCRIPTS_DIR)/firewall/setup_firewall.sh
	@echo ""
	@echo "Security layers active. Run 'make preflight' to verify all layers."

down: ## Stop containers
	docker compose down

restart: ## Restart containers and re-apply firewall rules
	docker compose restart
	@echo ""
	@echo "Re-applying firewall rules (requires sudo)..."
	sudo bash $(SCRIPTS_DIR)/firewall/setup_firewall.sh

logs: ## Show container logs (follow mode)
	docker logs -f $(CONTAINER_NAME)

status: ## Show container status
	@docker compose ps

preflight: sysbox-check ## Verify all security layers are active
	@echo ""
	@echo "=== OpenClaw Security Pre-flight ==="
	@echo ""
	@echo "[1/3] Sysbox runtime ............. OK"
	@echo ""
	@echo "[2/3] Firewall rules ..."
	@if sudo iptables -L FORWARD -n 2>/dev/null | grep -q "OPENCLAW-FIREWALL"; then \
		echo "      OK - OPENCLAW-FIREWALL rules are present"; \
	else \
		echo "      FAIL - no firewall rules found"; \
		echo "      Fix: make up  (firewall is now applied automatically)"; \
		exit 1; \
	fi
	@echo ""
	@echo "[3/3] Container status ..."
	@if docker ps --filter "name=$(CONTAINER_NAME)" --filter "status=running" 2>/dev/null | grep -q "$(CONTAINER_NAME)"; then \
		echo "      OK - container is running"; \
	else \
		echo "      FAIL - container is not running"; \
		echo "      Fix: make up"; \
		exit 1; \
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
	sudo bash $(SCRIPTS_DIR)/firewall/setup_firewall.sh

firewall-flush: ## Remove firewall rules
	sudo bash $(SCRIPTS_DIR)/firewall/setup_firewall.sh --flush

test: ## Test SSH connection to HOST
ifndef HOST
	@echo "Error: HOST parameter required. Usage: make test HOST=name"
	@exit 1
endif
	@echo "Testing SSH connection to $(HOST)..."
	docker exec -it $(CONTAINER_NAME) ssh $(HOST) whoami

# ------------------------------------------------------------------------------
# Cleanup
# ------------------------------------------------------------------------------

clean: ## Remove generated runtime files (htpasswd, tmp data)
	rm -rf .openclaw-data/tmp 2>/dev/null || true
	rm -f nginx/.htpasswd 2>/dev/null || true
	@echo "Runtime files removed"

purge: ## Full cleanup including config files (WARNING: destructive)
	@echo "WARNING: This will remove all OpenClaw data including configuration files!"
	@read -p "Are you sure? (y/N): " confirm && [ "$$confirm" = "y" ] || exit 1
	$(MAKE) uninstall
	rm -f .env config.json
	rm -rf .openclaw-data
	@echo "Purge complete"
