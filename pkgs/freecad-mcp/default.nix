{ pkgs, ... }:

let
  packageVersion = "0.1.19";

  addon = pkgs.stdenvNoCC.mkDerivation {
    pname = "freecad-mcp-addon";
    version = packageVersion;

    src = pkgs.fetchurl {
      url = "https://files.pythonhosted.org/packages/46/6b/7640024af2adcc8726918a4fb5297184ba30af6e7b92b8209c3a692e5241/freecad_mcp-${packageVersion}.tar.gz";
      hash = "sha256-CMAnd8fO/y1wEd50V74vs3fgGA6Q+WescSi5BG+wEko=";
    };

    sourceRoot = "freecad_mcp-${packageVersion}";

    installPhase = ''
      runHook preInstall

      mkdir -p $out
      cp -R addon/FreeCADMCP $out/FreeCADMCP

      runHook postInstall
    '';
  };

  package = pkgs.lib.mkPackageDerivation {
    inherit pkgs;
    hashKey = "freecad-mcp";
    packageManager = "pip";
    packageName = "freecad-mcp";
    inherit packageVersion;
    name = "freecad-mcp";
    exposedBinaries = [
      "freecad-mcp"
    ];
  };
in
package.overrideAttrs (old: {
  passthru = (old.passthru or { }) // {
    inherit addon;
  };
})
