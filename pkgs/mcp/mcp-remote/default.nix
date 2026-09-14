{ pkgs, ... }:

pkgs.lib.mkPackageDerivation {
  inherit pkgs;
  hashKey = "mcp-remote";
  packageManager = "npm";
  packageName = "mcp-remote";
  packageVersion = "0.14.2";
  name = "mcp-remote";
  exposedBinaries = [
    "mcp-remote"
  ];
}
