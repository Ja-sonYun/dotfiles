{ pkgs, ... }:

let
  name = "rpiv-i18n";
  packageName = "@juicesharp/rpiv-i18n";
  package = pkgs.lib.mkPackageDerivation {
    inherit pkgs name packageName;
    hashKey = "rpiv-i18n";
    packageManager = "npm";
    packageVersion = "1.19.1";
  };
in
package // {
  piExtensionPath = "${package}/node_modules/${name}/lib/node_modules/${packageName}";
}
