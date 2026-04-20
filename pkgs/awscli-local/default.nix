{ pkgs, ... }:

pkgs.lib.mkPackageDerivation rec {
  inherit pkgs;
  hashKey = "awscli-local";
  packageManager = "pip";
  packageName = "awscli-local";
  packageVersion = "0.22.2";
  name = "awscli-local";
  pythonVersion = "312";
  packageSpec = "'awscli-local[ver1]'==${packageVersion}";
  extraPackages = [
    "setuptools>=40.8.0"
  ];
  exposedBinaries = [
    "awslocal"
  ];
}
