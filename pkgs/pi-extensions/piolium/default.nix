{ pkgs, ... }:

let
  name = "piolium";
  packageName = "@vigolium/piolium";
  package = pkgs.lib.mkPackageDerivation {
    inherit pkgs name packageName;
    hashKey = "piolium";
    packageManager = "npm";
    packageVersion = "0.0.10";
    postInstall = ''
      substituteInPlace "$NODE_PATH/lib/node_modules/${packageName}/extensions/piolium/index.ts" \
        --replace-fail '		ctx.ui.notify(PIOLIUM_STARTUP_HINT, "info");' \
        '		// Startup hint disabled by dotfiles wrapper.'
    '';
  };
in
package
// {
  piExtensionPath = "${package}/node_modules/${name}/lib/node_modules/${packageName}";
}
