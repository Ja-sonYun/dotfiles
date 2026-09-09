# macOS VM

Run the shared dotfiles configuration in a disposable Parallels VM from the repository root.
Use an Apple Silicon Mac with Nix, initialized submodules, and activated Parallels Desktop Pro or Business. Open Parallels once before creating the VM.

## Create and use

```sh
make vm-create
make vm-start
make vm-ssh
```

`vm-create` loads the Packer environment from the root flake automatically. It reuses the package in `infra` without entering the infrastructure development shell.
Creation installs macOS, creates the account, enables SSH, installs Nix, applies nix-darwin and Home Manager, and shuts down. `vm-start` registers the resulting bundle and waits for SSH.

| Setting                 | Default                                                      |
| ----------------------- | ------------------------------------------------------------ |
| Guest                   | macOS Tahoe 26.0, build 25A354                               |
| VM name / Darwin output | `dotfiles-vm`                                                |
| Account / home          | `nixvm` / `/Users/nixvm`                                     |
| CPU / memory / disk     | 4 / 8192 MB / 131072 MB                                      |
| Bootstrap Nix           | 2.35.2; subsequently managed by the repository configuration |

The guest uses the shared shell and CLI configuration. Personal secrets, Homebrew, GUI applications, Linux builder, and radare2's secret-dependent decai integration are excluded.
The guest administrator has passwordless sudo for unattended deployment. Apple Account sign-in and FileVault are skipped during setup.

## Apply local changes

```sh
make vm-apply
make vm-status
make vm-ssh VM_COMMAND='nix --version'
```

`vm-apply` requires a running VM and transfers current working-tree contents, including uncommitted changes, new files, and deletions. It builds and activates only `darwinConfigurations.dotfiles-vm`; it does not reinstall macOS or Nix.

Source snapshots preserve initialized submodules and relative symlinks. Git metadata, environment files, encrypted payloads, conventional private-key files, and build caches are excluded. These filename filters do not identify secrets stored under arbitrary names.
The same filtered snapshot supplies the host Packer shell, preventing repository-local caches from entering that flake source.

Guest builds use the snapshot's `flake.lock` with `--no-update-lock-file`. They do not invoke the repository's ordinary `build`, `deploy`, or hash-update targets.
The VM package overlay reads `Jays-MacBook-Pro.json` because both configurations use the same ARM Darwin package recipes. The guest hostname remains `dotfiles-vm`; no VM-specific hash file is needed. Do not run hash-update scripts for this VM.

VM outputs and the Packer shell are defined in `vm/default.nix`. `vm/macos/configuration.nix` assembles shared modules and guest-only settings without registering a production host or adding VM conditions to common modules. The root flake merges these outputs while sharing its existing lock.

## Stop, remove, or resize

```sh
make vm-stop
make vm-remove
make vm-create PKR_VAR_cpus=6 PKR_VAR_memory=16384 PKR_VAR_disk_size=196608
make vm-start
```

`vm-remove` requires a stopped VM. It removes this instance and its credentials while retaining the downloaded IPSW cache. Creation refuses an existing instance or a conflicting registered VM name.
Resource variables apply when creating a new VM; they do not resize an existing guest.

## Files and failures

Runtime files live outside the repository:

```text
~/Parallels/dotfiles-vm/macos/
  cache/
  instance/
    output/dotfiles-vm.macvm/
    source/
    source.tar
    ssh/
    credentials.pkrvars.hcl
    logs/create.log
    logs/apply.log
```

The credentials file contains the generated console-login password. Credentials, SSH keys, and logs are private to the host user. SSH uses a per-instance known-hosts file.

- Setup stalls: inspect the VM window and `logs/create.log`. The Packer run is limited to six hours and may leave a partial instance on failure. Remove that instance before retrying.
- A partial VM remains registered without a recorded UUID: stop and unregister that VM in Parallels, then run `make vm-remove`. The helper refuses to guess ownership.
- SSH times out: inspect the guest console and Parallels Tools, then retry `make vm-start`. First contact records the SSH host key; subsequent key changes are rejected.
- Build or activation fails: inspect `logs/create.log` for the first deployment or `logs/apply.log` for later applications. Fix the source and retry creation or `make vm-apply`, respectively. A failed build does not start activation; activation errors do not trigger automatic rollback.
- A lock update is required: resolve the repository inputs before retrying. The VM helper does not update them.

Setup Assistant automation is tied to the pinned Tahoe image and its English screens. The screen sequence is adapted from the [Parallels Tahoe example](https://github.com/Parallels/packer-examples/blob/main/macos/provisioner_tahoe_26.pkr.hcl); the MIT notice is retained in the template.

## Future Ubuntu support

`VM_OS` defaults to `macos`. Other values currently fail explicitly.
An Ubuntu extension would add `vm/ubuntu/`, a Linux Home Manager output, ARM Linux package support and hashes, and a separate runtime directory. No Ubuntu VM is implemented here.
