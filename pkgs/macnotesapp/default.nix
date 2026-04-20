{ pkgs, ... }:

pkgs.lib.mkPackageDerivation {
  inherit pkgs;
  hashKey = "macnotesapp";
  packageManager = "pip";
  packageName = "macnotesapp";
  packageVersion = "0.8.2";
  name = "macnotesapp";
  pythonVersion = "312";
  exposedBinaries = [
    "notes"
  ];
}
