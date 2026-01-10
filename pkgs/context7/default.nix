{ pkgs, ... }:
let
  outputHash = pkgs.hashfile."context7-mcp";
in

pkgs.lib.npm.mkNpmGlobalPackageDerivation {
  inherit pkgs outputHash;
  name = "context7-mcp";
  packages = [
    "@upstash/context7-mcp@2.1.0"
  ];
  exposedBinaries = [
    "context7-mcp"
  ];
}
