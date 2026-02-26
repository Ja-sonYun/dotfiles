{ pkgs, ... }:
let
  outputHash = pkgs.hashfile."opencode";
in

pkgs.lib.npm.mkNpmGlobalPackageDerivation {
  inherit pkgs outputHash;
  name = "opencode";
  packages = [
    "opencode-ai@1.2.15"
  ];
  exposedBinaries = [
    "opencode"
  ];
}
