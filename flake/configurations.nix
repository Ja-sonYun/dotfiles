{ inputs }:
let
  inherit (inputs)
    agenix
    agenix-secrets
    darwin
    home-manager
    nix-homebrew
    nixlib
    nixpkgs
    nixpkgs-stable
    server
    ;
  hostConfig = import ./hosts.nix;
  inherit (hostConfig) hosts;

  mkSpecialArgs =
    hostname:
    let
      host = hosts.${hostname};
    in
    {
      inherit hostname;
      inherit (host)
        system
        username
        useremail
        userhome
        paths
        tags
        ;
      hasTag = hostConfig.hasTag hostname;
      infraSrc = server;
      agenix-secrets = agenix-secrets.outPath;
      inherit
        agenix
        nixpkgs-stable
        nixlib
        ;
    };

  mkPkgsProvider =
    hostname:
    import nixpkgs {
      inherit (hosts.${hostname}) system;
      overlays =
        builtins.attrValues (import ../overlays { inherit inputs hostname; })
        ++ builtins.attrValues nixlib.overlays;
      config = {
        allowUnfree = true;
        cudaSupport = hostConfig.hasTag hostname "gpu";
      };
    };

  mkHomeManagerConfig =
    hostname:
    [
      agenix.homeManagerModules.default
      agenix-secrets.homeManagerModules.secrets
      ../modules/shell
      ../modules/programs
      ../shell
      ../misc/fonts
    ]
    ++ nixpkgs.lib.optionals (hostConfig.hasTag hostname "ai") [
      agenix-secrets.homeManagerModules.ai-agents
    ]
    ++ (
      if hosts.${hostname}.system == "aarch64-darwin" then
        [
          ../hosts/aarch64-darwin/homemanager.nix
        ]
      else if hosts.${hostname}.system == "x86_64-linux" then
        [
          ../hosts/x86_64-linux/homemanager.nix
        ]
      else
        [ ]
    );

  mkX86_64LinuxHomeConfiguration =
    hostname:
    home-manager.lib.homeManagerConfiguration {
      pkgs = mkPkgsProvider hostname;
      extraSpecialArgs = mkSpecialArgs hostname;
      modules = [
        ../hosts/x86_64-linux/core/nix-core.nix
      ]
      ++ (mkHomeManagerConfig hostname);
    };

  mkAarch64DarwinHomeConfiguration =
    hostname:
    let
      specialArgs = mkSpecialArgs hostname;
      pkgs = mkPkgsProvider hostname;
    in
    darwin.lib.darwinSystem {
      inherit (specialArgs) system;
      inherit specialArgs pkgs;
      modules = [
        agenix.darwinModules.default
        agenix-secrets.darwinModules.secrets

        ../hosts/aarch64-darwin/shell.nix

        ../hosts/aarch64-darwin/core/nix-core.nix
        ../hosts/aarch64-darwin/core/system.nix
        ../hosts/aarch64-darwin/core/host-users.nix
        ../hosts/aarch64-darwin/core/spotlight
        ../hosts/aarch64-darwin/core/menubar

        ../hosts/aarch64-darwin/homebrew.nix
        ../hosts/aarch64-darwin/core/display

        ../modules/services
        ../modules/services/darwin

        ../hosts/aarch64-darwin/services.nix

        home-manager.darwinModules.home-manager
        {
          home-manager = {
            useGlobalPkgs = true;
            useUserPackages = false;
            extraSpecialArgs = specialArgs;
            users.${specialArgs.username}.imports = [
              ../modules/services/darwin/home-manager.nix
            ]
            ++ mkHomeManagerConfig hostname;
          };
        }

        nix-homebrew.darwinModules.nix-homebrew
        {
          nix-homebrew = {
            enable = true;
            user = specialArgs.username;
            autoMigrate = true;
          };
        }
      ];
    };
in
{
  darwinConfigurations."Jays-MacBook-Pro" = mkAarch64DarwinHomeConfiguration "Jays-MacBook-Pro";
  darwinConfigurations."Jays-MacBook-Pro-Server" =
    mkAarch64DarwinHomeConfiguration "Jays-MacBook-Pro-Server";

  homeConfigurations."linux-devel" = mkX86_64LinuxHomeConfiguration "linux-devel";
  homeConfigurations."Jasonyun-wsl-server" = mkX86_64LinuxHomeConfiguration "Jasonyun-wsl-server";
}
