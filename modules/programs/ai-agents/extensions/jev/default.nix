{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.ai-agents.extensions.jev;
  package = pkgs.callPackage ./pkgs { };
  rules = lib.concatLists (
    lib.mapAttrsToList (
      target: definitions:
      lib.mapAttrsToList (name: rule: {
        inherit name;
        value = rule // {
          inherit target;
        };
      }) definitions
    ) cfg.rules
  );
  rulesFile = pkgs.writeText "ai-agent-jev-rules.json" (builtins.toJSON (lib.listToAttrs rules));
  arguments = [
    "--rules"
    "${rulesFile}"
    "--jev"
    "${pkgs.jev}/bin/jev"
  ]
  ++ lib.optional cfg.debugLog.enable "--debug-log";
  hookCommand = lib.escapeShellArgs ([ "${package}/bin/ai-agent-jev-hook" ] ++ arguments);
  nonEmptyString = lib.types.addCheck lib.types.str (
    value: builtins.match "[[:space:]]*" value == null
  );
  ruleType = lib.types.submodule (
    { name, ... }:
    {
      options = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Whether to evaluate this rule.";
        };

        title = lib.mkOption {
          type = nonEmptyString;
          default = name;
          description = "Display name included in coding-rule feedback.";
        };

        extensions = lib.mkOption {
          type = lib.types.listOf (
            lib.types.addCheck lib.types.str (value: builtins.match "\\.[A-Za-z0-9]+" value != null)
          );
          default = [ ];
          example = [
            ".py"
            ".pyi"
          ];
          description = "Case-insensitive final file extensions, or an empty list for every inspected file.";
        };

        instructions = lib.mkOption {
          type = nonEmptyString;
          description = "Independent violation criteria and exceptions sent to Jev.";
        };

        why = lib.mkOption {
          type = nonEmptyString;
          description = "Author-written explanation of why a violation matters.";
        };

        message = lib.mkOption {
          type = nonEmptyString;
          description = "Author-written correction guidance returned for a violation.";
        };
      };
    }
  );
in
{
  options.programs.ai-agents.extensions.jev = {
    enable = lib.mkEnableOption "Jev session rules and inspection tools";
    debugLog.enable = lib.mkEnableOption "raw Jev debug logs with seven-day retention";
    hookCommand = lib.mkOption {
      type = lib.types.str;
      default = hookCommand;
      readOnly = true;
      internal = true;
    };
    rules = lib.genAttrs [ "code" "tool" "task" ] (
      target:
      lib.mkOption {
        type = lib.types.attrsOf ruleType;
        default = { };
        description = "Static ${target} rules evaluated independently by Jev; MCP cannot modify them.";
      }
    );
  };

  config = lib.mkIf (config.programs.ai-agents.enable && cfg.enable) {
    assertions = [
      {
        assertion = builtins.length rules == builtins.length (lib.unique (map (rule: rule.name) rules));
        message = "Jev rule IDs must be unique across code, tool, and task groups.";
      }
    ]
    ++ lib.concatMap (rule: [
      {
        assertion = rule.value.target == "code" || rule.value.extensions == [ ];
        message = "Jev rule ${rule.name}: only code rules may specify extensions.";
      }
      {
        assertion = builtins.match "[A-Za-z0-9_-]+" rule.name != null;
        message = "Jev rule IDs may contain only letters, digits, underscores, and hyphens.";
      }
    ]) rules;

    programs.ai-agents.mcp.servers.jev-rules = {
      command = "${package}/bin/ai-agent-jev-mcp";
      args = arguments;
      env_vars = [
        "TYPESAFE_API_KEY"
        "XDG_CACHE_HOME"
      ];
    };
  };
}
