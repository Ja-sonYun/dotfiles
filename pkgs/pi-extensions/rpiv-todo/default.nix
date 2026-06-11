{ pkgs, ... }:

let
  name = "rpiv-todo";
  packageName = "@juicesharp/rpiv-todo";
  package = pkgs.lib.mkPackageDerivation {
    inherit pkgs name packageName;
    hashKey = "rpiv-todo";
    packageManager = "npm";
    packageVersion = "1.19.1";
  };
in
package // {
  piExtensionPath = "${package}/node_modules/${name}/lib/node_modules/${packageName}";
}
