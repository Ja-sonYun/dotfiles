{ pkgs, ... }:

pkgs.lib.mkPackageDerivation {
  inherit pkgs;
  hashKey = "mcp-remote";
  packageManager = "npm";
  packageName = "mcp-remote";
  packageVersion = "0.8.3";
  name = "mcp-remote";
  exposedBinaries = [
    "mcp-remote"
  ];
}
