{ pkgs, ... }:
let
  outputHash = pkgs.hashfile."firecrawl-mcp";
in

pkgs.lib.npm.mkNpmGlobalPackageDerivation {
  inherit pkgs outputHash;
  name = "firecrawl-mcp";
  packages = [
    "firecrawl-mcp@3.9.0"
  ];
  exposedBinaries = [
    "firecrawl-mcp"
  ];
}
