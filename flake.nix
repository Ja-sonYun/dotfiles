{
  description = "Nix for macOS configuration";

  nixConfig = {
    substituters = [
      "https://cache.nixos.org"
    ];
  };

  inputs = {
    self.submodules = true;

    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    nixpkgs-prev.url = "github:NixOS/nixpkgs/4724d5647207377bede08da3212f809cbd94a648";
    nixpkgs-stable.url = "github:NixOS/nixpkgs/release-25.05";

    pyproject-nix = {
      url = "github:pyproject-nix/pyproject.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    uv2nix = {
      url = "github:pyproject-nix/uv2nix";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.pyproject-nix.follows = "pyproject-nix";
    };
    pyproject-build-systems = {
      url = "github:pyproject-nix/build-system-pkgs";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.uv2nix.follows = "uv2nix";
    };

    home-manager = {
      url = "github:nix-community/home-manager/master";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    home-manager-stable = {
      url = "github:nix-community/home-manager/release-25.05";
      inputs.nixpkgs.follows = "nixpkgs-stable";
    };

    darwin = {
      url = "github:nix-darwin/nix-darwin/master";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nix-homebrew = {
      url = "github:zhaofengli/nix-homebrew";
      inputs.brew-src.url = "github:Homebrew/brew/master";
    };
    homebrew-bundle = {
      url = "github:homebrew/homebrew-bundle";
      flake = false;
    };
    homebrew-core = {
      url = "github:homebrew/homebrew-core";
      flake = false;
    };
    homebrew-cask = {
      url = "github:homebrew/homebrew-cask";
      flake = false;
    };

    agenix = {
      url = "github:ryantm/agenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    agenix-secrets = {
      url = ./shell/secrets;
      inputs.mkutils.follows = "mkutils";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    git-hooks = {
      url = "github:cachix/git-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    mkutils = {
      url = "github:Ja-sonYun/mkutils";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixlib = {
      url = ./libs/nixlib;
      inputs.nixpkgs.follows = "nixpkgs";
    };

    vim = {
      url = ./portable/vim;
      inputs.nixpkgs.follows = "nixpkgs";
    };

    server = {
      url = ./infra;
      flake = false;
    };
  };

  outputs =
    inputs:
    (import ./flake/configurations.nix { inherit inputs; })
    // (import ./flake/development.nix { inherit inputs; });
}
