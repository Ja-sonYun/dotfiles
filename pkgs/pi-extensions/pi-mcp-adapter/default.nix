{ pkgs, ... }:

let
  name = "pi-mcp-adapter";
  packageName = "pi-mcp-adapter";
  package = pkgs.lib.mkPackageDerivation {
    inherit pkgs name packageName;
    hashKey = "pi-mcp-adapter";
    packageManager = "npm";
    packageVersion = "2.10.0";
  };
in
package // {
  piExtensionPath = "${package}/node_modules/${name}/lib/node_modules/${packageName}";
}
