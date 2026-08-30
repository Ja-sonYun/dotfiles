{ pkgs, ... }:

pkgs.lib.mkPackageDerivation {
  inherit pkgs;
  hashKey = "pi-mcp-adapter";
  packageManager = "npm";
  packageName = "pi-mcp-adapter";
  packageVersion = "2.31.0";
  name = "pi-mcp-adapter";
  exposedBinaries = [
    "pi-mcp-adapter"
  ];
  postInstall = ''
    ln -s "$NODE_PATH/lib/node_modules/pi-mcp-adapter" "$out/extension"
  '';
}
