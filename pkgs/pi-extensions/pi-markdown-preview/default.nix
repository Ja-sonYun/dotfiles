{ pkgs, ... }:

let
  name = "pi-markdown-preview";
  packageName = "pi-markdown-preview";
  package = pkgs.lib.mkPackageDerivation {
    inherit pkgs name packageName;
    hashKey = "pi-markdown-preview";
    packageManager = "npm";
    packageVersion = "0.10.0";
  };
in
package // {
  piExtensionPath = "${package}/node_modules/${name}/lib/node_modules/${packageName}";
}
