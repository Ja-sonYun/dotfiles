#!/usr/bin/env bash
set -euo pipefail

[[ $(uname -sm) == 'Darwin arm64' && $(id -un) == nixvm && $(hostname -s) == dotfiles-vm ]] || {
	printf 'This script only runs inside the dotfiles-vm macOS guest as nixvm.\n' >&2
	exit 1
}

sudo -n true
case "${1:-}" in
	install)
		curl -fsSL https://releases.nixos.org/nix/nix-2.35.2/install |
		sh -s -- --daemon --yes --no-channel-add
		;;
	apply) ;;
	*) printf 'Expected install or apply.\n' >&2; exit 1 ;;
esac

. /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh

nix --extra-experimental-features 'nix-command flakes' build \
	--no-update-lock-file \
	--out-link /Users/nixvm/dotfiles-system \
	'path:/Users/nixvm/dotfiles#darwinConfigurations.dotfiles-vm.system'

sudo /Users/nixvm/dotfiles-system/sw/bin/darwin-rebuild switch \
	--no-update-lock-file \
	--flake 'path:/Users/nixvm/dotfiles#dotfiles-vm'
