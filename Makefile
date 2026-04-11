# OpenClaw Makefile
# Simplified interface for installation, container management, and cleanup
#
# Usage:
#   make install          - Full installation
#   make uninstall        - Full uninstallation
#   make help             - Show all available targets
#
# Host-specific targets (require HOST parameter):
#   make chroot HOST=name       - Set up chroot for a host
#   make key-add HOST=name      - Install SSH key to host chroot
#   make key-remove HOST=name   - Remove SSH key from host chroot
#   make sync HOST=name         - Re-sync SSH key (alias for key-add)
#   make test HOST=name         - Test SSH connection to host

.PHONY: help install uninstall config keys auth up down restart logs status \
        chroot chroot-clean key-add key-remove sync firewall firewall-flush test clean purge

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
	@echo "  chroot            Set up chroot jail for HOST"
	@echo "  chroot-clean      Tear down chroot for HOST"
	@echo "  key-add           Install SSH key to HOST chroot"
	@echo "  key-remove        Remove SSH key from HOST chroot"
	@echo "  sync              Re-sync SSH key to HOST (alias for key-add)"
	@echo "  test              Test SSH connection to HOST"
	@echo ""
	@echo "Examples:"
	@echo "  make install                    # Full installation"
	@echo "  make chroot HOST=my-host        # Set up chroot for my-host"
	@echo "  make test HOST=my-host          # Test SSH to my-host"
	@echo "  make logs                       # Show container logs"

# ------------------------------------------------------------------------------
# Installation
# ------------------------------------------------------------------------------

install: ## Full installation (containers, keys, chroot)
	@echo "=== Installing OpenClaw ==="
	sudo bash $(SCRIPTS_DIR)/install.sh

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
	sudo bash $(SCRIPTS_DIR)/nginx/init_htpasswd.sh

# ------------------------------------------------------------------------------
# Container Management
# ------------------------------------------------------------------------------

up: ## Start containers
	docker compose up -d

down: ## Stop containers
	docker compose down

restart: ## Restart containers
	docker compose restart

logs: ## Show container logs (follow mode)
	docker logs -f $(CONTAINER_NAME)

status: ## Show container status
	@docker compose ps

# ------------------------------------------------------------------------------
# Chroot Management (requires HOST parameter)
# ------------------------------------------------------------------------------

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

# ------------------------------------------------------------------------------
# Maintenance
# ------------------------------------------------------------------------------

key-add: ## Install SSH key to HOST chroot
ifndef HOST
	@echo "Error: HOST parameter required. Usage: make key-add HOST=name"
	@exit 1
endif
	sudo bash $(SCRIPTS_DIR)/ssh_key/add.sh
	sudo systemctl reload sshd

key-remove: ## Remove SSH key from HOST chroot
ifndef HOST
	@echo "Error: HOST parameter required. Usage: make key-remove HOST=name"
	@exit 1
endif
	sudo bash $(SCRIPTS_DIR)/ssh_key/remove.sh
	sudo systemctl reload sshd

sync: ## Re-sync SSH key to HOST (alias for key-add)
ifndef HOST
	@echo "Error: HOST parameter required. Usage: make sync HOST=name"
	@exit 1
endif
	sudo bash $(SCRIPTS_DIR)/ssh_key/add.sh
	sudo systemctl reload sshd

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

clean: ## Remove temporary files
	rm -rf .openclaw-data/tmp 2>/dev/null || true
	@echo "Temporary files removed"

purge: ## Full cleanup including config files (WARNING: destructive)
	@echo "WARNING: This will remove all OpenClaw data including configuration files!"
	@read -p "Are you sure? (y/N): " confirm && [ "$$confirm" = "y" ] || exit 1
	$(MAKE) uninstall
	rm -f .env config.json
	rm -rf .openclaw-data
	@echo "Purge complete"
