{
  description = "Nix for macOS configuration";

  nixConfig = {
    substituters = [
      "https://cache.nixos.org"
    ];
  };

  inputs = {
    self.submodules = true;

    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixpkgs-prev.url = "github:NixOS/nixpkgs/4724d5647207377bede08da3212f809cbd94a648";
    nixpkgs-stable.url = "github:NixOS/nixpkgs/release-25.05";

    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
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

    # My packages
    # say.url = ./portable/say;
    # plot.url = ./portable/plot;
    # sequence-diagram-cli.url = ./portable/sequence-diagram-cli;
    vim = {
      url = ./portable/vim;
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # My personal server stuffs
    server = {
      url = ./infra;
      flake = false;
    };

    # Agenix for secret management
    agenix = {
      url = "github:ryantm/agenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    agenix-secrets = {
      url = ./shell/secrets/agenix;
      flake = false;
    };

    nixlib = {
      url = ./libs/nixlib;
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Git hooks for pre-commit
    git-hooks = {
      url = "github:cachix/git-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      nixlib,
      home-manager,
      nixpkgs-stable,
      home-manager-stable,
      darwin,
      nix-homebrew,
      homebrew-bundle,
      homebrew-core,
      homebrew-cask,
      vim,
      server,
      agenix,
      agenix-secrets,
      git-hooks,
      ...
    }:
    let
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
        hostname: pkgs:
        let
          specialArgs = specialArgsPrepared."${hostname}";
          system = specialArgs.system;
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
          inherit agenix agenix-secrets;
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
          system = specialArgs.system;
        in
        [
          # Agenix for secrets management
          agenix.homeManagerModules.default
          (import "${agenix-secrets}/homemanager.nix")
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
          isVM ? false,
          isWsl ? false,
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
            ./hosts/aarch64-darwin/shell.nix

            ./hosts/aarch64-darwin/core/nix-core.nix
            ./hosts/aarch64-darwin/core/system.nix
            ./hosts/aarch64-darwin/core/host-users.nix
            ./hosts/aarch64-darwin/core/spotlight
            ./hosts/aarch64-darwin/core/menubar

            ./hosts/aarch64-darwin/homebrew.nix
            ./hosts/aarch64-darwin/core/display
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
      checks = forAllSystems (system: {
        pre-commit-check = git-hooks.lib.${system}.run {
          src = ./.;
          hooks = {
            nixpkgs-fmt.enable = true;
          };
        };
      });
      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.mkShell {
            # inherit (self.checks.${system}.pre-commit-check) shellHook;
            # buildInputs = self.checks.${system}.pre-commit-check.enabledPackages ++ [
            #   pkgs.amber-lang
            # ];
            buildInputs = [
              pkgs.amber-lang
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
