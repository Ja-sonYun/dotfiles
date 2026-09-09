{ inputs }:
let
  pkgs = import inputs.nixpkgs {
    system = "aarch64-darwin";
    config.allowUnfreePredicate = pkg: inputs.nixpkgs.lib.getName pkg == "packer";
  };
in
{
  devShells.aarch64-darwin.vm = pkgs.mkShell {
    packages = [
      (import (inputs.server + "/nix/packages/packer-with-plugins.nix") { inherit pkgs; })
      pkgs.coreutils
    ];
  };

  darwinConfigurations.dotfiles-vm = import ./macos/configuration.nix { inherit inputs; };
}
