{ pkgs, ... }:

pkgs.lib.mkPackageDerivation {
  inherit pkgs;
  hashKey = "pi-mcp-adapter";
  packageManager = "npm";
  packageName = "pi-mcp-adapter";
  packageVersion = "2.11.0";
  name = "pi-mcp-adapter";
  exposedBinaries = [
    "pi-mcp-adapter"
  ];
  postInstall = ''
    substituteInPlace "$NODE_PATH/lib/node_modules/pi-mcp-adapter/init.ts" \
      --replace-fail 'ui.setStatus("mcp", ui.theme.fg("accent", `MCP: ''${connectedCount}/''${total} servers`));' \
                     'ui.setStatus("mcp", undefined);'
    ln -s "$NODE_PATH/lib/node_modules/pi-mcp-adapter" "$out/extension"
  '';
}
