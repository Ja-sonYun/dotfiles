{
  config,
  lib,
  ...
}:
let
  cfg = config.programs.ai-agents;
  sourceType =
    with lib.types;
    oneOf [
      package
      path
      str
    ];
in
{
  options.programs.ai-agents = {
    enable = lib.mkEnableOption "shared AI agent configuration";

    context = lib.mkOption {
      type = lib.types.nullOr lib.types.lines;
      default = null;
    };

    customInstructions = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = "Custom instructions shared by enabled AI agents.";
    };

    skills = lib.mkOption {
      type = lib.types.attrsOf sourceType;
      default = { };
    };

    extraPath = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      description = "Packages added to the PATH of every enabled AI agent.";
    };

    agentsDir = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      (lib.mkIf config.programs.codex.enable {
        programs.codex = lib.mkMerge [
          {
            inherit (cfg) skills extraPath;
          }
          (lib.mkIf (cfg.context != null) {
            inherit (cfg) context;
          })
          (lib.mkIf (cfg.customInstructions != "") {
            customInstructions = lib.mkBefore cfg.customInstructions;
          })
          (lib.mkIf (cfg.adaptedAgents != null) {
            agentsDir = "${cfg.adaptedAgents}/codex";
          })
        ];
      })

      (lib.mkIf config.programs.claude-code.enable {
        programs.claude-code = lib.mkMerge [
          {
            inherit (cfg) skills extraPath;
          }
          (lib.mkIf (cfg.context != null) {
            inherit (cfg) context;
          })
          (lib.mkIf (cfg.customInstructions != "") {
            customInstructions = lib.mkBefore cfg.customInstructions;
          })
          (lib.mkIf (cfg.adaptedAgents != null) {
            agentsDir = "${cfg.adaptedAgents}/claude";
          })
        ];
      })

      (lib.mkIf config.programs.pi.enable {
        programs.pi = lib.mkMerge [
          {
            inherit (cfg) skills extraPath;
          }
          (lib.mkIf (cfg.context != null) {
            inherit (cfg) context;
          })
          (lib.mkIf (cfg.customInstructions != "") {
            customInstructions = lib.mkBefore cfg.customInstructions;
          })
          (lib.mkIf (cfg.adaptedAgents != null) {
            agentsDir = "${cfg.adaptedAgents}/pi";
          })
        ];
      })
    ]
  );
}
