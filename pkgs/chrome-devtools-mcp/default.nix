{ pkgs, ... }:

pkgs.lib.mkPackageDerivation {
  inherit pkgs;
  hashKey = "chrome-devtools-mcp";
  packageManager = "npm";
  packageName = "chrome-devtools-mcp";
  packageVersion = "1.0.1";
  name = "chrome-devtools-mcp";
  exposedBinaries = [
    "chrome-devtools-mcp"
  ];
}
