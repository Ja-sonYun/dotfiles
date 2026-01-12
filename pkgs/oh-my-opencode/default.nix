{ pkgs, ... }:
let
  outputHash = pkgs.hashfile."oh-my-opencode";
in

pkgs.lib.npm.mkNpmGlobalPackageDerivation {
  inherit pkgs outputHash;
  name = "oh-my-opencode";
  packages = [
    "oh-my-opencode@2.14.0"
  ];
  exposedBinaries = [
    "oh-my-opencode"
  ];
}
