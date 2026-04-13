{
  description = "Development environment templates";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    nixpkgs-terraform.url = "github:NixOS/nixpkgs/0c19708cf035f50d28eb4b2b8e7a79d4dc52f6bb";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      nixpkgs-terraform,
      rust-overlay,
      ...
    }:
    let
      systems = nixpkgs.lib.systems.flakeExposed;

      forEachSystem =
        f:
        nixpkgs.lib.genAttrs systems (
          system:
          f {
            inherit system;
            pkgs = import nixpkgs {
              inherit system;
              overlays = [
                rust-overlay.overlays.default
                self.overlays.default
              ];
            };
            pkgs-terraform = import nixpkgs-terraform {
              inherit system;
              config.allowUnfree = true;
            };
          }
        );
    in
    {
      overlays.default = final: prev: {
        # Go
        go = final.go_1_25;

        # Rust stable toolchain
        rustToolchain =
          let
            rust = prev.rust-bin;
          in
          rust.stable.latest.default.override {
            extensions = [
              "rust-src"
              "rustfmt"
            ];
          };

        # Elixir / Erlang
        erlang = final.beam.interpreters.erlang_27;
        pkgs-beam = final.beam.packagesWith final.erlang;
        elixir = final.pkgs-beam.elixir_1_17;
      };

      devShells = forEachSystem (
        {
          pkgs,
          pkgs-terraform,
          system,
          ...
        }:
        let
          tlib = import ./lib.nix {
            inherit pkgs pkgs-terraform system;
          };
        in
        import ./shells.nix {
          inherit
            pkgs
            pkgs-terraform
            system
            tlib
            ;
        }
      );
    };
}
