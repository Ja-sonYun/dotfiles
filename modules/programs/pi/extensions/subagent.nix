{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.pi.settings.extensions.subagent;
  configDirs = [
    ".pi/agent"
  ]
  ++ lib.optional (config.programs.pi.dev.extensionsSource != null) ".pi/agent-dev";
in
{
  options.programs.pi.settings = lib.mkOption {
    type = lib.types.submodule {
      options.extensions.subagent = {
        enable = lib.mkEnableOption "Pi subagents";

        package = lib.mkOption {
          type = lib.types.package;
          default = pkgs.pi-extensions.subagent;
          description = "Vendored Pi subagent extension.";
        };

        agentsDir = lib.mkOption {
          type = lib.types.nullOr (
            lib.types.oneOf [
              lib.types.package
              lib.types.path
              lib.types.str
            ]
          );
          default = null;
          description = "Directory of Pi agent Markdown definitions.";
        };

        source = lib.mkOption {
          type = lib.types.str;
          internal = true;
          readOnly = true;
          default = "${cfg.package}";
          description = "Packaged Pi subagent extension directory.";
        };

        devSource = lib.mkOption {
          type = lib.types.str;
          internal = true;
          readOnly = true;
          default =
            if config.programs.pi.dev.extensionsSource == null then
              "${cfg.package}/index.ts"
            else
              "${config.programs.pi.dev.extensionsSource}/subagent/index.ts";
          description = "Mutable Pi subagent entry point for pi-dev.";
        };
      };
    };
  };

  config = lib.mkMerge [
    {
      programs.pi.settings.extensions.permissions.enable = lib.mkIf (
        config.programs.pi.enable && cfg.enable
      ) (lib.mkDefault true);
    }

    (lib.mkIf (config.programs.pi.enable && cfg.enable) {
      assertions = [
        {
          assertion = config.programs.pi.settings.extensions.permissions.enable;
          message = "Pi subagents require the parent permission extension.";
        }
      ];
      home.file = lib.mkIf (cfg.agentsDir != null) (
        lib.genAttrs (map (dir: "${dir}/agents") configDirs) (_: {
          source = cfg.agentsDir;
        })
      );
    })
  ];
}
