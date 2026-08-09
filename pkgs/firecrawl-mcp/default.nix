{ pkgs, ... }:

pkgs.lib.mkPackageDerivation {
  inherit pkgs;
  hashKey = "firecrawl-mcp";
  packageManager = "npm";
  packageName = "firecrawl-mcp";
  packageVersion = "3.23.6";
  name = "firecrawl-mcp";
  exposedBinaries = [
    "firecrawl-mcp"
  ];
}
