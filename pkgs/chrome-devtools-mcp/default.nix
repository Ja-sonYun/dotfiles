{ pkgs, ... }:
let
  outputHash = pkgs.hashfile."chrome-devtools-mcp";
in

pkgs.lib.npm.mkNpmGlobalPackageDerivation {
  inherit pkgs outputHash;
  name = "chrome-devtools-mcp";
  packages = [
    "chrome-devtools-mcp@0.13.0"
  ];
  exposedBinaries = [
    "chrome-devtools-mcp"
  ];
}
