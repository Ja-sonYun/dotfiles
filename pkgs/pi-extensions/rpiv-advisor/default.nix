{ pkgs, ... }:

let
  name = "rpiv-advisor";
  packageName = "@juicesharp/rpiv-advisor";
  package = pkgs.lib.mkPackageDerivation {
    inherit pkgs name packageName;
    hashKey = "rpiv-advisor";
    packageManager = "npm";
    packageVersion = "1.19.1";
  };
in
package // {
  piExtensionPath = "${package}/node_modules/${name}/lib/node_modules/${packageName}";
}
