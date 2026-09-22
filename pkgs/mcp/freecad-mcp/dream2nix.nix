{
  config,
  lib,
  pkgs,
  ...
}:
{
  lock.fields.freecadAddon.script = lib.getExe (
    pkgs.writeShellApplication {
      name = "lock-freecad-addon";
      runtimeInputs = [
        pkgs.curl
        pkgs.jq
      ];
      text = ''
        : "''${out:?dream2nix must provide an output path}"
        curl --fail --silent --show-error --location \
          'https://pypi.org/pypi/freecad-mcp/${config.version}/json' \
          | jq -e '[.urls[] | select(.packagetype == "sdist")][0]
              | {url, sha256: .digests.sha256}
              | select((.url | type) == "string" and (.sha256 | test("^[0-9a-f]{64}$")))' > "$out"
      '';
    }
  );

  public.addon = config.mkDerivation.passthru.addon;
  mkDerivation.passthru.addon = pkgs.stdenvNoCC.mkDerivation {
    pname = "freecad-mcp-addon";
    inherit (config) version;
    src = pkgs.fetchurl {
      inherit (config.lock.content.freecadAddon) url sha256;
    };
    sourceRoot = "freecad_mcp-${config.version}";
    installPhase = ''
      runHook preInstall
      mkdir -p "$out"
      cp -R addon/FreeCADMCP "$out/FreeCADMCP"
      runHook postInstall
    '';
  };
}
