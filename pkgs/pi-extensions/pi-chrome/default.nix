{ pkgs, ... }:

let
  name = "pi-chrome";
  packageName = "pi-chrome";
  package = pkgs.lib.mkPackageDerivation {
    inherit pkgs name packageName;
    hashKey = "pi-chrome";
    packageManager = "npm";
    packageVersion = "0.15.38";
  };
in
package // {
  piExtensionPath = "${package}/node_modules/${name}/lib/node_modules/${packageName}";
}
