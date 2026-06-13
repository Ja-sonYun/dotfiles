{ pkgs, ... }:

pkgs.lib.mkPackageDerivation {
  inherit pkgs;
  hashKey = "exa-mcp-server";
  packageManager = "npm";
  packageName = "exa-mcp-server";
  packageVersion = "3.2.1";
  name = "exa-mcp-server";
  exposedBinaries = [
    "exa-mcp-server"
  ];
}
