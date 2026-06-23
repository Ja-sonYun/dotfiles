{ pkgs, ... }:

pkgs.lib.mkPackageDerivation {
  inherit pkgs;
  hashKey = "pi";
  packageManager = "npm";
  packageName = "@earendil-works/pi-coding-agent";
  packageVersion = "0.79.10";
  name = "pi";
  exposedBinaries = [
    "pi"
  ];
}
