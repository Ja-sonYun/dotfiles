{ inputs }:
let
  system = "aarch64-darwin";
  username = "nixvm";
  userhome = "/Users/${username}";
  tags = [ ];
  specialArgs = {
    inherit
      system
      username
      userhome
      tags
      ;
    hostname = "dotfiles-vm";
    useremail = "nixvm@localhost";
    paths = {
      dotfiles = "${userhome}/dotfiles";
      cache = "${userhome}/.nixcache/${username}";
    };
    hasTag = (import ../../flake/tags.nix).has tags;
    infraSrc = inputs.server;
    inherit (inputs) agenix nixlib nixpkgs-stable;
  };
  pkgs = import inputs.nixpkgs {
    inherit system;
    config.allowUnfree = true;
    overlays =
      builtins.attrValues (
        import ../../overlays {
          inherit inputs;
          # Reuse hashes for the same ARM Darwin package recipes.
          hostname = "Jays-MacBook-Pro";
        }
      )
      ++ builtins.attrValues inputs.nixlib.overlays;
  };
  inherit (inputs.nixpkgs) lib;
in
inputs.darwin.lib.darwinSystem {
  inherit system pkgs specialArgs;
  modules = [
    ../../hosts/aarch64-darwin/shell.nix
    ../../hosts/aarch64-darwin/core/host-users.nix
    ../../modules/services
    ../../modules/services/darwin
    inputs.home-manager.darwinModules.home-manager
    {
      system.stateVersion = 5;
      system.primaryUser = username;

      nix = {
        enable = true;
        package = pkgs.nix;
        settings = {
          experimental-features = [
            "nix-command"
            "flakes"
            "impure-derivations"
            "ca-derivations"
          ];
          substituters = [
            "https://cache.nixos.org"
            "https://nix-community.cachix.org"
          ];
          trusted-public-keys = [
            "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
            "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
          ];
        };
      };

      programs.zsh = {
        enable = true;
        enableGlobalCompInit = false;
        enableBashCompletion = false;
      };
      security.sudo.extraConfig = ''
        ${username} ALL=(ALL) NOPASSWD: ALL
      '';

      home-manager = {
        useGlobalPkgs = true;
        useUserPackages = false;
        extraSpecialArgs = specialArgs;
        users.${username} = {
          imports = [
            ../../modules/services/darwin/home-manager.nix
            ../../modules/shell
            ../../modules/programs
            ../../shell
            ../../misc/fonts
            ../../hosts/aarch64-darwin/homemanager.nix
          ];

          programs.radare2 = {
            envFiles = lib.mkForce { };
            decai.enable = lib.mkForce false;
            extraConfig = lib.mkForce ''
              e scr.color=1
              e scr.utf8=true
              e scr.utf8.curvy=true
              e asm.bytes=false
              e dbg.hwbp=false
              e cfg.fortunes=false
              e bin.cache=true
              e r2ghidra.sleighhome=${pkgs.r2ghidra}/lib/radare2/last/r2ghidra_sleigh
            '';
          };
        };
      };
    }
  ];
}
