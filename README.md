# dotfiles

Personal system configuration using Nix Flakes, Home Manager, and nix-darwin.

## Fresh macOS setup

These steps are for a new Apple Silicon macOS machine.

### 1. Install Command Line Developer Tools

Install Apple's Command Line Developer Tools before cloning this repo. Running
`git` on a fresh macOS install may also show the installer prompt.

```sh
xcode-select --install
```

This installs `git` and other build tools. It can take around 10 minutes.

### 2. Set up GitHub SSH access

Create an SSH key and register the public key in GitHub.

```sh
ssh-keygen -t rsa
pbcopy < ~/.ssh/id_rsa.pub
```

Add the copied key to GitHub, then clone this repo over SSH. Most submodules use
SSH URLs, so HTTPS clone is not enough for a full setup.

```sh
git clone git@github.com:Ja-sonYun/dotfiles.git
cd dotfiles
git submodule update --init --recursive
```

### 3. Install Nix

Install Nix, then restart macOS or start a new shell so the Nix environment is
loaded.

```sh
sh <(curl --proto '=https' --tlsv1.2 -L https://nixos.org/nix/install)
```

### 4. Prepare the first deploy

Install Rosetta before deploying because this config manages Homebrew packages.

```sh
softwareupdate --install-rosetta --agree-to-license
```

Enter a bootstrap shell with the tools needed before the managed environment is
available.

```sh
nix-shell -p ripgrep coreutils gnused git
```

Back up the stock shell rc files before the first nix-darwin activation. The
activation creates managed `/etc/zshrc` and `/etc/bashrc` files.

```sh
sudo mv /etc/bashrc /etc/bashrc.before-nix-darwin
sudo mv /etc/zshrc /etc/zshrc.before-nix-darwin
```

Before running the first deploy, add Terminal to:

`System Settings > Privacy & Security > App Management`

### 5. Deploy

```sh
make deploy
```

On macOS, `make deploy` applies the nix-darwin configuration for the current host name.

## Usage

```sh
make update  # Update flakes and packages
make deploy  # Apply configuration
```
