{ pkgs, ... }:

let
  name = "pi-retry";
  packageName = "@narumitw/pi-retry";
  package = pkgs.lib.mkPackageDerivation {
    inherit pkgs name packageName;
    hashKey = "pi-retry";
    packageManager = "npm";
    packageVersion = "0.1.37";
  };
in
package // {
  piExtensionPath = "${package}/node_modules/${name}/lib/node_modules/${packageName}";
}
