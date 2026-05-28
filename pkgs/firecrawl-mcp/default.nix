{ pkgs, ... }:

pkgs.lib.mkPackageDerivation {
  inherit pkgs;
  hashKey = "firecrawl-mcp";
  packageManager = "npm";
  packageName = "firecrawl-mcp";
  packageVersion = "3.19.1";
  name = "firecrawl-mcp";
  exposedBinaries = [
    "firecrawl-mcp"
  ];
}
