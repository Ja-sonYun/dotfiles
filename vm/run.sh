#!/usr/bin/env bash
set -euo pipefail
umask 077

fail() {
	printf '%s\n' "$*" >&2
	exit 1
}

[[ ${1:-} == macos ]] || fail "Unsupported VM_OS: ${1:-unset}. Only macos is implemented."
[[ $(uname -sm) == 'Darwin arm64' ]] || fail 'VM commands require an Apple Silicon Mac.'

action=${2:?Missing VM action}
repo=$(cd "$(dirname "$0")/.." && pwd -P)
base="$HOME/Parallels/dotfiles-vm/macos"
instance="$base/instance"
bundle="$instance/output/dotfiles-vm.macvm"
snapshot="$instance/source"
vm_name=dotfiles-vm
guest_home=/Users/nixvm

command -v prlctl >/dev/null || fail 'Install and activate Parallels Desktop Pro or Business first.'
[[ ! -L "$instance" ]] || fail "Refusing symlinked instance directory: $instance"

ssh_options=(
	-i "$instance/ssh/id_ed25519"
	-o IdentitiesOnly=yes
	-o BatchMode=yes
	-o ConnectTimeout=5
	-o StrictHostKeyChecking=accept-new
	-o "UserKnownHostsFile=$instance/ssh/known_hosts"
)

require_instance() {
	[[ -f "$instance/owner" && $(cat "$instance/owner") == "$vm_name" ]] ||
	fail "No managed instance. Run make vm-create."
}

registered_ids() {
	prlctl list --all --no-header | awk '{ print $1 }'
}

is_registered() {
	local ids
	ids=$(registered_ids) || fail 'Cannot query Parallels. Open and activate Parallels Desktop first.'
	[[ -f "$instance/uuid" ]] && printf '%s\n' "$ids" | grep -Fxq "$(cat "$instance/uuid")"
}

vm_state() {
	prlctl list "$(cat "$instance/uuid")" --all --no-header -o status | awk '{$1=$1; print}'
}

require_running() {
	require_instance
	is_registered || fail 'VM is not registered. Run make vm-start.'
	[[ $(vm_state) == running ]] || fail 'VM is not running. Run make vm-start.'
}

wait_for_ssh() {
	local attempt addresses
	for ((attempt = 0; attempt < 60; attempt++)); do
		addresses=$(prlctl list "$(cat "$instance/uuid")" --full --no-header -o ip_configured) || return 1
		guest_ip=$(printf '%s\n' "$addresses" | tr ', ' '\n\n' |
		awk '/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ { print; exit }')
		if [[ -n "$guest_ip" ]] && ssh "${ssh_options[@]}" "nixvm@$guest_ip" true 2>/dev/null; then
			return
		fi
		sleep 2
	done
	fail 'SSH did not become ready. Check the VM console and Parallels Tools; then retry make vm-start.'
}

prepare_source() {
	local submodules input
	submodules=$(git -C "$repo" submodule status --recursive) || fail 'Cannot inspect submodules.'
	if printf '%s\n' "$submodules" | grep -Eq '^[-U]'; then
		fail 'Initialize the repository submodules before creating or applying the VM.'
	fi
	for input in shell/secrets libs/nixlib portable/vim infra; do
		[[ -f "$repo/$input/flake.nix" ]] || fail "Missing local flake input: $input"
	done
	mkdir -p "$snapshot"
	rsync -a --delete --delete-excluded \
		--exclude='.git' --exclude='.env' --exclude='.env.*' \
		--exclude='*.env' --exclude='*.env.*' --exclude='*.age' \
		--exclude='.ssh/' --exclude='id_rsa' --exclude='id_ed25519' \
		--exclude='id_ecdsa' --exclude='*.pem' --exclude='*.key' \
		--exclude='.tmp/' --exclude='.direnv/' --exclude='.cache/' \
		--exclude='.local/' --exclude='.claude/' --exclude='.envrc' \
		--exclude='node_modules/' --exclude='__pycache__/' --exclude='.venv/' \
		--exclude='result' --exclude='result-*' --exclude='*.macvm/' --exclude='*.pvm/' \
		"$repo/" "$snapshot/"
}

case "$action" in
	create)
		[[ ! -e "$instance" ]] || fail 'An instance already exists. Stop and remove it before creating another.'
		names=$(prlctl list --all --no-header -o name) || fail 'Cannot query Parallels Desktop.'
		if printf '%s\n' "$names" | grep -Fxq "$vm_name"; then
			fail "A VM named $vm_name already exists; it will not be overwritten."
		fi
		command -v nix >/dev/null || fail 'Nix must be installed on the host.'
		mkdir -p "$base/cache" "$instance/ssh" "$instance/logs"
		printf '%s\n' "$vm_name" > "$instance/owner"
		ssh-keygen -q -t ed25519 -N '' -C "$vm_name" -f "$instance/ssh/id_ed25519"
		password=$(openssl rand -hex 16)
		printf 'ssh_password = "%s"\n' "$password" > "$instance/credentials.pkrvars.hcl"
		unset password
		prepare_source
		tar -cf "$instance/source.tar" -C "$snapshot" .
		export PACKER_CACHE_DIR="$base/cache"
		export PKR_VAR_output_directory="$instance/output"
		export PKR_VAR_source_archive="$instance/source.tar"
		export PKR_VAR_public_key_file="$instance/ssh/id_ed25519.pub"
		printf 'Creating %s. Log: %s\n' "$vm_name" "$instance/logs/create.log"
		if nix develop "path:$snapshot#vm" --no-update-lock-file \
			--command timeout --signal=INT --kill-after=60s 6h packer build \
			-var-file="$instance/credentials.pkrvars.hcl" "$repo/vm/macos" \
			2>&1 | tee "$instance/logs/create.log"; then
			[[ -d "$bundle" ]] || fail "Packer finished without the expected bundle: $bundle"
			printf 'Created %s\nRun make vm-start to boot it.\n' "$bundle"
		else
			fail "Creation failed or exceeded six hours. See $instance/logs/create.log."
		fi
		;;
	start)
		require_instance
		[[ -d "$bundle" ]] || fail "No completed VM bundle at $bundle."
		if ! is_registered; then
			names=$(prlctl list --all --no-header -o name) || fail 'Cannot query Parallels Desktop.'
			if printf '%s\n' "$names" | grep -Fxq "$vm_name"; then
				fail "Another registered VM is named $vm_name; refusing to use it."
			fi
			prlctl register "$bundle" --preserve-uuid
			prlctl list "$vm_name" --all --no-header | awk '{ print $1 }' > "$instance/uuid"
			[[ -s "$instance/uuid" ]] || fail 'Could not obtain the registered VM UUID.'
		fi
		if [[ $(vm_state) != running ]]; then
			prlctl start "$(cat "$instance/uuid")"
		fi
		wait_for_ssh
		printf 'SSH ready: nixvm@%s\n' "$guest_ip"
		;;
	status)
		if [[ ! -d "$instance" ]]; then
			printf 'No instance. Run make vm-create.\n'
			exit 0
		fi
		require_instance
		printf 'Bundle: %s\nLogs: %s\n' "$bundle" "$instance/logs"
		if is_registered; then
			prlctl list "$(cat "$instance/uuid")" --all
			if [[ $(vm_state) == running ]]; then
				prlctl list "$(cat "$instance/uuid")" --full --no-header -o ip_configured
			fi
		else
			printf 'Not registered. Run make vm-start if creation completed.\n'
		fi
		;;
	ssh)
		require_running
		wait_for_ssh
		if [[ -n ${VM_COMMAND:-} ]]; then
			exec ssh "${ssh_options[@]}" "nixvm@$guest_ip" "$VM_COMMAND"
		fi
		exec ssh -t "${ssh_options[@]}" "nixvm@$guest_ip"
		;;
	apply)
		require_running
		wait_for_ssh
		prepare_source
		printf -v remote_shell '%q ' ssh "${ssh_options[@]}"
		rsync -a --delete -e "$remote_shell" "$snapshot/" "nixvm@$guest_ip:$guest_home/dotfiles/"
		ssh "${ssh_options[@]}" "nixvm@$guest_ip" \
			'/bin/bash /Users/nixvm/dotfiles/vm/macos/provision.sh apply' \
			2>&1 | tee "$instance/logs/apply.log"
		;;
	stop)
		require_instance
		if is_registered && [[ $(vm_state) != stopped ]]; then
			prlctl stop "$(cat "$instance/uuid")"
		fi
		;;
	remove)
		require_instance
		if is_registered; then
			[[ $(vm_state) == stopped ]] || fail 'Stop the VM with make vm-stop before removing it.'
			prlctl unregister "$(cat "$instance/uuid")"
		else
			names=$(prlctl list --all --no-header -o name) || fail 'Cannot query Parallels Desktop.'
			if printf '%s\n' "$names" | grep -Fxq "$vm_name"; then
				fail "A VM named $vm_name is registered without a recorded UUID. Inspect it in Parallels before removing this instance."
			fi
		fi
		rm -rf -- "$instance"
		printf 'Removed instance. Image cache retained at %s\n' "$base/cache"
		;;
	*) fail "Unknown VM action: $action" ;;
esac
