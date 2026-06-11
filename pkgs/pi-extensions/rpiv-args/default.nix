{ pkgs, ... }:

let
  name = "rpiv-args";
  packageName = "@juicesharp/rpiv-args";
  package = pkgs.lib.mkPackageDerivation {
    inherit pkgs name packageName;
    hashKey = "rpiv-args";
    packageManager = "npm";
    packageVersion = "1.19.1";
  };
in
package // {
  piExtensionPath = "${package}/node_modules/${name}/lib/node_modules/${packageName}";
}
