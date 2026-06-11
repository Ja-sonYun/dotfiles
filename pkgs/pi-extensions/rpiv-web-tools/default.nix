{ pkgs, ... }:

let
  name = "rpiv-web-tools";
  packageName = "@juicesharp/rpiv-web-tools";
  package = pkgs.lib.mkPackageDerivation {
    inherit pkgs name packageName;
    hashKey = "rpiv-web-tools";
    packageManager = "npm";
    packageVersion = "1.19.1";
  };
in
package // {
  piExtensionPath = "${package}/node_modules/${name}/lib/node_modules/${packageName}";
}
