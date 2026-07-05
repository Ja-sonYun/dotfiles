MAKEFLAGS += --no-print-directory

HELP_PROJECT_NAME := Dotfiles
HELP_WIDTH := 20

HOSTNAME := $(shell hostname -s)
SYSTEM := $(shell uname -s)

ifeq ($(shell command -v nom),)
  NIX := nix
else
  NIX := nom
endif

ifndef NIX_CONFIG
NIX_GITHUB_TOKEN := $(shell command -v gh >/dev/null 2>&1 && gh auth token 2>/dev/null || true)
ifeq ($(NIX_GITHUB_TOKEN),)
define NIX_CONFIG
experimental-features = nix-command flakes
endef
else
define NIX_CONFIG
experimental-features = nix-command flakes
access-tokens = github.com=$(NIX_GITHUB_TOKEN)
endef
endif
endif
export NIX_CONFIG

ifdef TRACE
NIX_TRACE_ARGS := --show-trace
endif

# ==================================================================================
##@ Update

push-secrets: ## Push secrets to git
	(cd ./shell/secrets && make push) || true

update-vim: ## Update vim flake
	cd ./portable/vim && nix flake update

update-raw: update-vim ## Update all flakes
	nix flake update

update-versions: ## Update package versions
	./scripts/update-versions

update-pkgs: update-versions ## Update package versions

update: push-secrets ## Full update with ulimit fix
	@sh -c 'set -eu; \
	orig_ulimit=$$(ulimit -n || echo 0); \
	trap "ulimit -n $$orig_ulimit >/dev/null 2>&1 || true" EXIT; \
	if [ "$$orig_ulimit" -lt 65536 ] 2>/dev/null; then ulimit -n 65536 || true; fi; \
		$(MAKE) update-raw update-pkgs'
# ==================================================================================

build-pkgs: ## Build packages that need hash updates
	./scripts/build-pkgs

# ==================================================================================
ifeq ($(SYSTEM),Linux)
##@ Linux

install: ## Install nix daemon
	sh <(curl -L https://nixos.org/nix/install) --daemon

deploy: build-pkgs add lock ## Deploy home-manager config
	$(NIX) build .#homeConfigurations.$(HOSTNAME).activationPackage $(NIX_TRACE_ARGS)
	./result/activate
endif
# ==================================================================================

# ==================================================================================
ifeq ($(SYSTEM),Darwin)
##@ Darwin

LINUX_BUILDER := system/org.nixos.linux-builder

linux-builder-up: ## Start linux-builder VM and wait until SSH-ready
	@sudo launchctl kickstart $(LINUX_BUILDER) 2>/dev/null || true
	@printf 'waiting for linux-builder'; \
	for i in $$(seq 1 60); do \
	  if sudo ssh -o StrictHostKeyChecking=no -o ConnectTimeout=2 linux-builder true 2>/dev/null; \
	    then echo ' ready'; exit 0; fi; \
	  printf '.'; sleep 1; \
	done; echo ' timeout'; exit 1

linux-builder-down: ## Stop the linux-builder VM
	@sudo launchctl kill TERM $(LINUX_BUILDER) 2>/dev/null || true

build: build-pkgs add lock ## Build nix-darwin config
	@$(MAKE) linux-builder-up
	$(NIX) build .#darwinConfigurations.$(HOSTNAME).system $(NIX_TRACE_ARGS)

show-derivations: ## Show derivation details
	nix show-derivation .#darwinConfigurations.$(HOSTNAME).system

deploy: build ## Deploy nix-darwin config
	nix run nixpkgs#nh darwin switch .#darwinConfigurations.$(HOSTNAME)
	@$(MAKE) linux-builder-down
endif
# ==================================================================================

# ==================================================================================
##@ Maintenance

fmt: ## Format nix files
	nixpkgs-fmt .

check: ## Run pre-commit checks
	pre-commit run --all-files

clean: ## Clean nix store
	nix run nixpkgs#nh clean
# ==================================================================================

# ==================================================================================
##@ Git

init-submodules: ## Initialize all submodules
	git submodule update --init --recursive

fix-submodules: ## Fix broken submodules (deinit + reinit)
	git submodule deinit --all -f
	git submodule update --init --recursive

update-submodules: ## Update all submodules to latest
	git submodule update --remote --recursive
# ==================================================================================

#---

add:
	git add .

lock: add
	nix flake update vim
	nix flake update server
