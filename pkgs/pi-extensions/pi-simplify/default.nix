{ pkgs, ... }:

let
  name = "pi-simplify";
  packageName = "pi-simplify";
  package = pkgs.lib.mkPackageDerivation {
    inherit pkgs name packageName;
    hashKey = "pi-simplify";
    packageManager = "npm";
    packageVersion = "0.2.2";
  };
in
package // {
  piExtensionPath = "${package}/node_modules/${name}/lib/node_modules/${packageName}";
}
