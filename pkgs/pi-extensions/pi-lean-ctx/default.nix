{ pkgs, ... }:

let
  name = "pi-lean-ctx";
  packageName = "pi-lean-ctx";
  package = pkgs.lib.mkPackageDerivation {
    inherit pkgs name packageName;
    hashKey = "pi-lean-ctx";
    packageManager = "npm";
    packageVersion = "3.7.5";
  };
in
package // {
  piExtensionPath = "${package}/node_modules/${name}/lib/node_modules/${packageName}";
}
