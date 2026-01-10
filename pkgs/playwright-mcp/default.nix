{ pkgs, ... }:
let
  outputHash = pkgs.hashfile."playwright-mcp";
in

pkgs.lib.npm.mkNpmGlobalPackageDerivation {
  inherit pkgs outputHash;
  name = "playwright-mcp";
  packages = [
    "@playwright/mcp@0.0.55"
  ];
  exposedBinaries = [
    "mcp-server-playwright"
  ];
}
