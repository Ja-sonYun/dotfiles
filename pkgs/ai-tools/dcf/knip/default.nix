{ pkgs, ... }:

pkgs.lib.mkPackageDerivation {
  inherit pkgs;
  hashKey = "knip";
  packageManager = "npm";
  packageName = "knip";
  packageVersion = "6.37.0";
  name = "knip";
  exposedBinaries = [
    "knip"
  ];
}
