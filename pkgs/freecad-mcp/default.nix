{ pkgs, ... }:

let
  packageVersion = "0.1.17";

  addon = pkgs.stdenvNoCC.mkDerivation {
    pname = "freecad-mcp-addon";
    version = packageVersion;

    src = pkgs.fetchurl {
      url = "https://files.pythonhosted.org/packages/c3/06/fbc421b116de60b30918430b39f0c21d3a930243b00af042d14d371713f7/freecad_mcp-${packageVersion}.tar.gz";
      hash = "sha256-DugQWGZizIXO27cjzfyidNTyyahN1BTcDNTl4DHWqN0=";
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
