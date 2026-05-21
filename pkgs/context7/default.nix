{ pkgs, ... }:

pkgs.lib.mkPackageDerivation {
  inherit pkgs;
  hashKey = "context7-mcp";
  packageManager = "npm";
  packageName = "@upstash/context7-mcp";
  packageVersion = "2.3.0";
  name = "context7-mcp";
  exposedBinaries = [
    "context7-mcp"
  ];
}
