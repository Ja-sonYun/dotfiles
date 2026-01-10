MAKEFLAGS += --no-print-directory

include .mkutils/colors.mk
include .mkutils/help.mk

HELP_PROJECT_NAME := Dotfiles
HELP_WIDTH := 20

HOSTNAME := $(shell hostname -s)
SYSTEM := $(shell uname -s)

ifeq ($(shell command -v nom),)
  NIX := nix
else
  NIX := nom
endif

NIX_CONFIG ?= experimental-features = nix-command flakes
export NIX_CONFIG

ifdef TRACE
NIX_TRACE_ARGS := --show-trace
endif


# ==================================================================================
##@ Update

update-vim: ## Update vim flake
	cd ./portable/vim && nix flake update

update-raw: update-vim ## Update all flakes
	nix flake update

update-pkgs: update-raw ## Update flakes and package versions
	./scripts/update-versions

update: ## Full update with ulimit fix
	@sh -c 'set -eu; \
	orig_ulimit=$$(ulimit -n || echo 0); \
	trap "ulimit -n $$orig_ulimit >/dev/null 2>&1 || true" EXIT; \
	if [ "$$orig_ulimit" -lt 65536 ] 2>/dev/null; then ulimit -n 65536 || true; fi; \
		$(MAKE) update-raw update-pkgs'
# ==================================================================================



# ==================================================================================
ifeq ($(SYSTEM),Linux)
##@ Linux

install: ## Install nix daemon
	sh <(curl -L https://nixos.org/nix/install) --daemon

deploy: add lock ## Deploy home-manager config
	nix run home-manager -- switch --flake .#$(HOSTNAME)
endif
# ==================================================================================



# ==================================================================================
ifeq ($(SYSTEM),Darwin)
##@ Darwin

build: add lock ## Build nix-darwin config
	$(NIX) build .#darwinConfigurations.$(HOSTNAME).system $(NIX_TRACE_ARGS)

show-derivations: ## Show derivation details
	nix show-derivation .#darwinConfigurations.$(HOSTNAME).system

deploy: build ## Deploy nix-darwin config
	nix run nixpkgs#nh darwin switch .#darwinConfigurations.$(HOSTNAME)
	sudo yabai --load-sa || true
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

