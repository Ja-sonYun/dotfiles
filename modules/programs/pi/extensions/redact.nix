{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.pi.settings.extensions.redact;
in
{
  options.programs.pi.settings = lib.mkOption {
    type = lib.types.submodule {
      options.extensions.redact = {
        enable = lib.mkEnableOption "Pi shell output redaction";
        package = lib.mkOption {
          type = lib.types.package;
          default = pkgs.pi-extensions.redact;
          description = "Pi redact extension package.";
        };
        source = lib.mkOption {
          type = lib.types.str;
          internal = true;
          readOnly = true;
          default = "${cfg.package}/index.ts";
          description = "Packaged redact extension entry point.";
        };
        devSource = lib.mkOption {
          type = lib.types.str;
          internal = true;
          readOnly = true;
          default =
            if config.programs.pi.dev.extensionsSource == null then
              cfg.source
            else
              "${config.programs.pi.dev.extensionsSource}/redact/index.ts";
          description = "Mutable redact extension entry point for pi-dev.";
        };
      };
    };
  };

  config = lib.mkIf (config.programs.pi.enable && cfg.enable) {
    programs.pi.env.PI_REDACT_EXECUTABLE = "${pkgs.redact}/bin/redact";
  };
}
