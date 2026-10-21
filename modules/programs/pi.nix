{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.pi;
  exports = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (name: value: ''
      if [ -z "''${${name}+x}" ]; then
        ${
          if builtins.isAttrs value then
            ''
              ${name}="$(${pkgs.coreutils}/bin/cat -- ${lib.escapeShellArg value._secret})" || exit "$?"
              export ${name}
            ''
          else
            "export ${name}=${lib.escapeShellArg value}"
        }
      fi
    '') cfg.env
  );
  package =
    if cfg.env == { } && cfg.extraExtensions == [ ] then
      cfg.package
    else
      pkgs.runCommand "pi-environment" { nativeBuildInputs = [ pkgs.makeWrapper ]; } ''
        mkdir -p "$out/bin"
        makeWrapper ${cfg.package}/bin/pi "$out/bin/pi" \
          --run ${lib.escapeShellArg exports} \
          --add-flags ${
            lib.escapeShellArg (
              lib.escapeShellArgs (
                lib.concatMap (path: [
                  "--extension"
                  path
                ]) cfg.extraExtensions
              )
            )
          }
        makeWrapper ${cfg.package}/bin/pi-dev "$out/bin/pi-dev" --prefix PATH : "$out/bin"
      '';
in
{
  options.programs.pi = {
    enable = lib.mkEnableOption "Pi coding agent";
    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.pi;
      description = "Standalone Pi package.";
    };
    env = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.either lib.types.str (
          lib.types.submodule {
            options._secret = lib.mkOption {
              type = lib.types.str;
              description = "Secret file read at launch.";
            };
          }
        )
      );
      default = { };
      description = "Environment defaults; inherited values take precedence.";
    };
    extraExtensions = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Additional extension paths loaded by Pi.";
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ package ];
  };
}
