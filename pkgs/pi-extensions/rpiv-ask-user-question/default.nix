{ pkgs, ... }:

let
  name = "rpiv-ask-user-question";
  packageName = "@juicesharp/rpiv-ask-user-question";
  package = pkgs.lib.mkPackageDerivation {
    inherit pkgs name packageName;
    hashKey = "rpiv-ask-user-question";
    packageManager = "npm";
    packageVersion = "1.19.1";
  };
in
package // {
  piExtensionPath = "${package}/node_modules/${name}/lib/node_modules/${packageName}";
}
