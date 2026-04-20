{ pkgs, ... }:
let
  outputHash = pkgs.hashfile."drawio-mcp";
in

pkgs.lib.npm.mkNpmGlobalPackageDerivation {
  inherit pkgs outputHash;
  name = "drawio-mcp";
  packages = [
    "@drawio/mcp@1.2.6"
  ];
  exposedBinaries = [
    "drawio-mcp"
  ];
}
