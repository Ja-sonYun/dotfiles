{ pkgs, ... }:

let
  name = "pi-lens";
  packageName = "pi-lens";
  package = pkgs.lib.mkPackageDerivation {
    inherit pkgs name packageName;
    hashKey = "pi-lens";
    packageManager = "npm";
    packageVersion = "3.8.53";
  };
in
package
// {
  piExtensionPath = "${package}/node_modules/${name}/lib/node_modules/${packageName}";
}
