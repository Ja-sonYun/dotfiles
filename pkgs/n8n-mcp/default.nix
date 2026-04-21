{ pkgs, ... }:

pkgs.lib.mkPackageDerivation {
  inherit pkgs;
  hashKey = "n8n-mcp";
  packageManager = "npm";
  packageName = "n8n-mcp";
  packageVersion = "2.47.13";
  name = "n8n-mcp";
  exposedBinaries = [
    "n8n-mcp"
  ];
}
