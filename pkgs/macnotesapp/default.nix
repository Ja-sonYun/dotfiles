{ pkgs, ... }:
let
  outputHash = pkgs.hashfile."macnotesapp";
in

pkgs.lib.pip.mkPipGlobalPackageDerivation {
  inherit pkgs outputHash;
  name = "macnotesapp";
  pythonVersion = "312";
  packages = [
    "macnotesapp==0.8.2"
  ];
  exposedBinaries = [
    "notes"
  ];
}
