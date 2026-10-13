{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.pi.settings.extensions.tool-summaries;
  jsonFormat = pkgs.formats.json { };
in
{
  options.programs.pi.settings = lib.mkOption {
    type = lib.types.submodule {
      options.extensions.tool-summaries = {
        enable = lib.mkEnableOption "Pi tool call and permission summaries";
        package = lib.mkOption {
          type = lib.types.package;
          default = pkgs.pi-extensions.tool-summaries;
          description = "Pi tool summaries extension package.";
        };
        provider = lib.mkOption {
          type = lib.types.nonEmptyStr;
          description = "Registered Pi provider for tool summaries.";
        };
        model = lib.mkOption {
          type = lib.types.nonEmptyStr;
          description = "Model ID used to summarize tool calls and permission prompts.";
        };
        source = lib.mkOption {
          type = lib.types.str;
          internal = true;
          readOnly = true;
          default = "${cfg.package}/index.ts";
          description = "Packaged tool summaries extension entry point.";
        };
        devSource = lib.mkOption {
          type = lib.types.str;
          internal = true;
          readOnly = true;
          default =
            if config.programs.pi.dev.extensionsSource == null then
              cfg.source
            else
              "${config.programs.pi.dev.extensionsSource}/tool-summaries/index.ts";
          description = "Mutable tool summaries extension entry point for pi-dev.";
        };
      };
    };
  };

  config = lib.mkIf (config.programs.pi.enable && cfg.enable) {
    programs.pi.env.PI_TOOL_SUMMARIES_CONFIG = toString (
      jsonFormat.generate "pi-tool-summaries.json" {
        inherit (cfg) provider model;
      }
    );
  };
}
