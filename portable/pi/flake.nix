{
  description = "Portable Pi runtime and resource package";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    dream2nix = {
      url = "github:nix-community/dream2nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };
  outputs =
    {
      self,
      nixpkgs,
      dream2nix,
    }:
    let
      systems = builtins.filter (
        system: builtins.fromJSON (builtins.readFile (./. + "/lock.${system}.json")) != { }
      ) (builtins.attrNames (builtins.fromJSON (builtins.readFile ./package-spec.json)).versions);
    in
    {
      overlays.default = import ./overlay.nix { inherit dream2nix; };
      packages = nixpkgs.lib.genAttrs systems (
        system:
        let
          pkgs = import nixpkgs {
            inherit system;
            overlays = [ self.overlays.default ];
          };
        in
        {
          default = pkgs.pi;
          inherit (pkgs)
            pi
            pi-runtime
            pi-resources
            ;
          pi-dev = pkgs.pi;
          pi-lock = pkgs.pi-runtime.lock;
        }
      );
      apps = nixpkgs.lib.genAttrs systems (system: {
        default = {
          type = "app";
          program = "${self.packages.${system}.pi}/bin/pi";
        };
        pi-dev = {
          type = "app";
          program = "${self.packages.${system}.pi}/bin/pi-dev";
        };
      });
    };
}
