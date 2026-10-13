{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.pi.settings.extensions.permissions;
  jsonFormat = pkgs.formats.json { };
  configFile = jsonFormat.generate "pi-permissions.json" {
    inherit (cfg) policy;
    parser = "${pkgs.shfmt}/bin/shfmt";
    search = "${pkgs.ripgrep}/bin/rg";
    evaluator = config.programs.ai-agents.extensions.rules.evaluatorCommand;
  };
in
{
  options.programs.pi.settings = lib.mkOption {
    type = lib.types.submodule {
      options.extensions.permissions = {
        enable = lib.mkEnableOption "Pi permission checks and parent-owned approvals";
        package = lib.mkOption {
          type = lib.types.package;
          default = pkgs.pi-extensions.permissions;
          description = "Pi permission extension package.";
        };
        policy = lib.mkOption {
          inherit (jsonFormat) type;
          internal = true;
          description = "Runtime policy supplied by the common permissions module.";
        };
        source = lib.mkOption {
          type = lib.types.str;
          internal = true;
          readOnly = true;
          default = "${cfg.package}/index.ts";
          description = "Packaged permission extension entry point.";
        };
        devSource = lib.mkOption {
          type = lib.types.str;
          internal = true;
          readOnly = true;
          default =
            if config.programs.pi.dev.extensionsSource == null then
              cfg.source
            else
              "${config.programs.pi.dev.extensionsSource}/permissions/index.ts";
          description = "Mutable permission extension entry point for pi-dev.";
        };
      };
    };
  };

  config = lib.mkIf (config.programs.pi.enable && cfg.enable) {
    programs.pi.env.PI_PERMISSIONS_CONFIG = toString configFile;
    assertions = [
      {
        assertion = config.programs.ai-agents.enable && config.programs.ai-agents.permissions != null;
        message = "Pi permissions require the shared AI agent permission policy.";
      }
      {
        assertion = config.programs.ai-agents.extensions.rules.enable;
        message = "Pi permissions require the shared rule evaluator.";
      }
      {
        assertion = config.programs.pi.env ? TYPESAFE_API_KEY;
        message = "Pi permissions require a runtime TYPESAFE_API_KEY (use the existing agenix secret).";
      }
    ];
  };
}
