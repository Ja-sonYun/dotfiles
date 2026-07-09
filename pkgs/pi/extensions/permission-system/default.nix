{ pkgs, ... }:

pkgs.lib.mkPackageDerivation {
  inherit pkgs;
  hashKey = "pi-permission-system";
  packageManager = "npm";
  packageName = "pi-permission-system";
  packageVersion = "0.8.0";
  name = "pi-permission-system";
  exposedBinaries = [ ];
  # Anchor pinned to upstream 0.8.0; re-check on version bump.
  postInstall = ''
    substituteInPlace "$NODE_PATH/lib/node_modules/pi-permission-system/src/permission-dialog.ts" \
      --replace-fail 'const selected = await ui.select(' \
                     'import("node:child_process").then(cp=>cp.execFile("${pkgs.pi-extensions.hooks.fireHook}",["Notification","permission_prompt"],()=>{})).catch(()=>{}); const selected = await ui.select('
    ln -s "$NODE_PATH/lib/node_modules/pi-permission-system" "$out/extension"
  '';
}
