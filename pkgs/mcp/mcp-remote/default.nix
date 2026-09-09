{ pkgs, ... }:

pkgs.lib.mkPackageDerivation {
  inherit pkgs;
  hashKey = "mcp-remote";
  packageManager = "npm";
  packageName = "mcp-remote";
  packageVersion = "0.8.5";
  name = "mcp-remote";
  exposedBinaries = [
    "mcp-remote"
  ];
}
