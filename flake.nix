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

    # Nix-Homebrew to install casks
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
      flake = false;
    };
    git-hooks = {
      url = "github:cachix/git-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    mkutils = {
      url = "github:Ja-sonYun/mkutils";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    aoe = {
      url = "github:agent-of-empires/agent-of-empires";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixlib = {
      url = ./libs/nixlib;
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # My packages
    vim = {
      url = ./portable/vim;
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # My personal server stuffs
    server = {
      url = ./infra;
      flake = false;
    };
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      nixlib,
      home-manager,
      nixpkgs-stable,
      darwin,
      nix-homebrew,
      server,
      agenix,
      agenix-secrets,
      git-hooks,
      mkutils,
      aoe,
      ...
    }:
    let
      inherit (nixpkgs) lib;
      excludedPaths =
        let
          lines = lib.splitString "\n" (builtins.readFile ./.gitmodules);
          pathLines = builtins.filter (l: lib.hasInfix "path = " l) lines;
          submodulePaths = map (l: lib.trim (lib.last (lib.splitString " = " l))) pathLines;
        in
        submodulePaths ++ [ "portable/vim" ];
      excludeRegexes = map (p: "^" + lib.escapeRegex p + "/") excludedPaths;

      specialArgsPrepared = {
        "Jays-MacBook-Pro" = {
          system = "aarch64-darwin";
          username = "jaykuroyanagi";
          useremail = "jason@abex.dev";
          hostname = "Jays-MacBook-Pro";
          userhome = "/Users/jaykuroyanagi";
          configDir = "/Users/jaykuroyanagi/dotfiles";
          cacheDir = "/Users/jaykuroyanagi/.nixcache/jaykuroyanagi";
          purpose = "main";
        };
        "Jays-MacBook-Pro-Server" = {
          system = "aarch64-darwin";
          username = "jaykuroyanagi";
          useremail = "jason@abex.dev";
          hostname = "Jays-MacBook-Pro-Server";
          userhome = "/Users/jaykuroyanagi";
          configDir = "/Users/jaykuroyanagi/dotfiles";
          cacheDir = "/Users/jaykuroyanagi/.nixcache/jaykuroyanagi";
          purpose = "server";
        };
        "linux-devel" = {
          system = "x86_64-linux";
          username = "vagrant";
          useremail = "jason@abex.dev";
          hostname = "linux-devel";
          userhome = "/home/vagrant";
          configDir = "/home/vagrant/dotfiles";
          cacheDir = "/home/vagrant/.nixcache/jasony";
          purpose = "server";
        };
        "Jasonyun-wsl-server" = {
          system = "x86_64-linux";
          username = "jason";
          useremail = "jason@abex.dev";
          hostname = "Jasonyun-wsl-server";
          userhome = "/home/jason";
          configDir = "/home/jason/dotfiles";
          cacheDir = "/home/jason/.nixcache/jason";
          purpose = "server";
        };
      };
      mkSpecialArgs =
        hostname: _pkgs:
        let
          specialArgs = specialArgsPrepared."${hostname}";
          inherit (specialArgs) system;
        in
        {
          inherit system;
          inherit (specialArgs)
            username
            useremail
            hostname
            userhome
            configDir
            cacheDir
            purpose
            ;
          infraSrc = server;
          inherit
            agenix
            agenix-secrets
            nixpkgs-stable
            nixlib
            aoe
            ;
        };

      mkPkgsProvider =
        system: hostname:
        {
          cudaSupport ? false,
        }:
        import nixpkgs {
          inherit system;
          overlays =
            builtins.attrValues (import ./overlays { inherit inputs hostname; })
            ++ builtins.attrValues nixlib.overlays;
          config = {
            allowUnfree = true;
            inherit cudaSupport;
          };
        };

      mkHomeManagerConfig =
        hostname:
        let
          specialArgs = specialArgsPrepared."${hostname}";
          inherit (specialArgs) system;
        in
        [
          # Agenix for secrets management
          agenix.homeManagerModules.default
          (import "${agenix-secrets}/homemanager.nix")
          ./modules/shell
          ./modules/programs
          # Common configurations
          ./shell
          ./misc/fonts
        ]
        ++ (
          if system == "aarch64-darwin" then
            [
              # Mac os specific configurations
              ./hosts/aarch64-darwin/homemanager.nix
            ]

          else if system == "x86_64-linux" then
            [
              # Linux specific configurations, which isn't implemented yet
              ./hosts/x86_64-linux/homemanager.nix
              ./hosts/x86_64-linux/services.nix
            ]
          else
            [ ]
        );

      mkX86_64LinuxHomeConfiguration =
        hostname:
        opts@{
          cudaSupport ? false,
        }:
        let
          system = specialArgsPrepared."${hostname}".system;
          pkgs = mkPkgsProvider system hostname { inherit cudaSupport; };
          extraSpecialArgs = (mkSpecialArgs hostname pkgs) // opts;
        in
        home-manager.lib.homeManagerConfiguration {
          inherit extraSpecialArgs pkgs;
          modules = [
            # System configurations
            ./hosts/x86_64-linux/core/nix-core.nix
          ]
          ++ (mkHomeManagerConfig hostname);
        };

      mkAarch64DarwinHomeConfiguration =
        hostname:
        opts@{ }:
        let
          system = specialArgsPrepared."${hostname}".system;
          pkgs = mkPkgsProvider system hostname { };
          specialArgs = (mkSpecialArgs hostname pkgs) // opts;
        in
        darwin.lib.darwinSystem {
          inherit system specialArgs pkgs;
          modules = [
            # System configurations
            agenix.darwinModules.default
            (import "${agenix-secrets}/systemmanager.nix")

            ./hosts/aarch64-darwin/shell.nix

            ./hosts/aarch64-darwin/core/nix-core.nix
            ./hosts/aarch64-darwin/core/system.nix
            ./hosts/aarch64-darwin/core/host-users.nix
            ./hosts/aarch64-darwin/core/spotlight
            ./hosts/aarch64-darwin/core/menubar

            ./hosts/aarch64-darwin/homebrew.nix
            ./hosts/aarch64-darwin/core/display

            ./modules/services

            ./hosts/aarch64-darwin/services.nix

            # home manager
            home-manager.darwinModules.home-manager
            {
              home-manager = {
                useGlobalPkgs = true;
                useUserPackages = false;
                extraSpecialArgs = specialArgs;
                users.${specialArgs.username}.imports = mkHomeManagerConfig hostname;
              };
            }

            nix-homebrew.darwinModules.nix-homebrew
            {
              nix-homebrew = {
                enable = true;
                enableRosetta = true;
                user = specialArgs.username;
                # Automatically migrate existing Homebrew installations
                autoMigrate = true;
              };
            }
          ];
        };

      supportedSystems = [
        "aarch64-darwin"
        "x86_64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
    in
    {
      checks = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          statixConfig = (pkgs.formats.toml { }).generate "statix.toml" {
            disabled = [ "repeated_keys" ];
            ignore = excludedPaths;
          };
        in
        {
          pre-commit-check = git-hooks.lib.${system}.run {
            src = ./.;
            excludes = excludeRegexes;
            hooks = {
              nixfmt.enable = true;
              deadnix.enable = true;
              deadnix.settings.noLambdaPatternNames = true;
              statix.enable = true;
              statix.settings.config = toString statixConfig;
              beautysh = {
                enable = true;
                name = "beautysh";
                package = pkgs.beautysh;
                entry = "${pkgs.beautysh}/bin/beautysh --tab";
                types = [ "shell" ];
                excludes = [
                  "^scripts/update-versions$"
                  "^scripts/build-pkgs$"
                ];
              };
              prettier.enable = true;
              taplo.enable = true;
            };
          };
        }
      );
      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.mkShell {
            inherit (self.checks.${system}.pre-commit-check) shellHook;
            buildInputs = self.checks.${system}.pre-commit-check.enabledPackages ++ [
              pkgs.amber-lang
              mkutils.packages.${system}.default
            ];
          };
        }
      );

      darwinConfigurations."Jays-MacBook-Pro" = mkAarch64DarwinHomeConfiguration "Jays-MacBook-Pro" { };
      darwinConfigurations."Jays-MacBook-Pro-Server" =
        mkAarch64DarwinHomeConfiguration "Jays-MacBook-Pro-Server"
          { };

      homeConfigurations."linux-devel" = mkX86_64LinuxHomeConfiguration "linux-devel" {
        cudaSupport = false;
        isVM = true;
      };
      homeConfigurations."Jasonyun-wsl-server" = mkX86_64LinuxHomeConfiguration "Jasonyun-wsl-server" {
        cudaSupport = true;
        isVM = false;
        isWsl = true;
      };
    };
}
