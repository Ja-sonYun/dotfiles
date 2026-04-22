{ pkgs, ... }:

pkgs.lib.mkPackageDerivation {
  inherit pkgs;
  hashKey = "chrome-devtools-mcp";
  packageManager = "npm";
  packageName = "chrome-devtools-mcp";
  packageVersion = "0.22.0";
  name = "chrome-devtools-mcp";
  exposedBinaries = [
    "chrome-devtools-mcp"
  ];
}
