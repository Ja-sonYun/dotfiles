{ pkgs, ... }:

let
  packageVersion = "0.1.22";

  addon = pkgs.stdenvNoCC.mkDerivation {
    pname = "freecad-mcp-addon";
    version = packageVersion;

    src = pkgs.fetchPypi {
      pname = "freecad_mcp";
      version = packageVersion;
      hash = "sha256-Zqd/Ec53g1VdmFQENy5yAUO9vgLmYdoZgDvHI95X+jE=";
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
