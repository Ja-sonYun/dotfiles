{ pkgs, ... }:

let
  name = "pi-subagents";
  packageName = "pi-subagents";
  package = pkgs.lib.mkPackageDerivation {
    inherit pkgs name packageName;
    hashKey = "pi-subagents";
    packageManager = "npm";
    packageVersion = "0.28.0";
  };
in
package // {
  piExtensionPath = "${package}/node_modules/${name}/lib/node_modules/${packageName}";
}
