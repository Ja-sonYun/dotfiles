{ pkgs, ... }:

let
  name = "pi-permission-system";
  packageName = "@gotgenes/pi-permission-system";
  package = pkgs.lib.mkPackageDerivation {
    inherit pkgs name packageName;
    hashKey = "pi-permission-system";
    packageManager = "npm";
    packageVersion = "16.0.1";
  };
in
package // {
  piExtensionPath = "${package}/node_modules/${name}/lib/node_modules/${packageName}";
}
