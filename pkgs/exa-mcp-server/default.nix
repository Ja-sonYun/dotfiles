{ pkgs, ... }:

pkgs.lib.mkPackageDerivation {
  inherit pkgs;
  hashKey = "exa-mcp-server";
  packageManager = "npm";
  packageName = "exa-mcp-server";
  packageVersion = "3.4.0";
  name = "exa-mcp-server";
  exposedBinaries = [
    "exa-mcp-server"
  ];
}
