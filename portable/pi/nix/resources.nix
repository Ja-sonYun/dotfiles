{ pkgs }:
let
  source = pkgs.lib.cleanSourceWith {
    src = ../.;
    filter =
      path: _:
      let
        relative = pkgs.lib.removePrefix "${toString ../.}/" path;
      in
      builtins.elem (builtins.head (pkgs.lib.splitString "/" relative)) [
        "package.json"
        "package-lock.json"
        "extensions"
        "redaction"
        "config"
      ]
      && !(builtins.elem (baseNameOf path) [
        "node_modules"
        ".git"
        "__pycache__"
        "tests"
      ]);
  };
in
pkgs.buildNpmPackage {
  pname = "pi-resources";
  version = "0.1.0";
  src = source;
  npmDeps = pkgs.importNpmLock { npmRoot = source; };
  npmConfigHook = pkgs.importNpmLock.npmConfigHook;
  dontNpmBuild = true;
  installPhase = ''
    mkdir -p "$out"
    cp -R package.json extensions redaction config node_modules "$out/"
  '';
}
