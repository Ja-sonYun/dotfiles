{ pkgs, ... }:

let
  packageVersion = "0.1.20";

  addon = pkgs.stdenvNoCC.mkDerivation {
    pname = "freecad-mcp-addon";
    version = packageVersion;

    src = pkgs.fetchPypi {
      pname = "freecad_mcp";
      version = packageVersion;
      hash = "sha256-z2PYQPysMiPJEOmXE3zzphk8OTrgWZExenoXLWtl6VM=";
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
