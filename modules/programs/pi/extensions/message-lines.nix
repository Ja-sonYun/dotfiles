{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.pi.settings.extensions.message-lines;
in
{
  options.programs.pi.settings = lib.mkOption {
    type = lib.types.submodule {
      options.extensions.message-lines = {
        enable = lib.mkEnableOption "Pi transparent message lines";
        package = lib.mkOption {
          type = lib.types.package;
          default = pkgs.pi-extensions.message-lines;
          description = "Pi message lines extension package.";
        };
        source = lib.mkOption {
          type = lib.types.str;
          internal = true;
          readOnly = true;
          default = "${cfg.package}/index.ts";
          description = "Packaged message lines extension entry point.";
        };
        devSource = lib.mkOption {
          type = lib.types.str;
          internal = true;
          readOnly = true;
          default =
            if config.programs.pi.dev.extensionsSource == null then
              cfg.source
            else
              "${config.programs.pi.dev.extensionsSource}/message-lines/index.ts";
          description = "Mutable message lines extension entry point for pi-dev.";
        };
      };
    };
  };
}
