{ pkgs, ... }:

pkgs.lib.mkPackageDerivation {
  inherit pkgs;
  hashKey = "pi-permission-system";
  packageManager = "npm";
  packageName = "pi-permission-system";
  packageVersion = "0.8.0";
  name = "pi-permission-system";
  exposedBinaries = [ ];
  postInstall = ''
    ln -s "$NODE_PATH/lib/node_modules/pi-permission-system" "$out/extension"
  '';
}
