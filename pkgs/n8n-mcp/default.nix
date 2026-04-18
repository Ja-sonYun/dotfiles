{ pkgs, ... }:
let
  outputHash = pkgs.hashfile."n8n-mcp";
in

pkgs.lib.npm.mkNpmGlobalPackageDerivation {
  inherit pkgs outputHash;
  name = "n8n-mcp";
  packages = [
    "n8n-mcp@2.47.12"
  ];
  exposedBinaries = [
    "n8n-mcp"
  ];
}
