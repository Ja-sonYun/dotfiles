{ pkgs, ... }:

pkgs.lib.mkPackageDerivation {
  inherit pkgs;
  hashKey = "semble";
  packageManager = "pip";
  packageName = "semble";
  packageVersion = "0.1.7";
  packageSpec = "'semble[mcp]==0.1.7'";
  name = "semble";
  exposedBinaries = [
    "semble"
  ];
}
