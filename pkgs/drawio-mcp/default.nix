{ pkgs, ... }:

pkgs.lib.mkPackageDerivation {
  inherit pkgs;
  hashKey = "drawio-mcp";
  packageManager = "npm";
  packageName = "@drawio/mcp";
  packageVersion = "1.2.6";
  name = "drawio-mcp";
  exposedBinaries = [
    "drawio-mcp"
  ];
}
