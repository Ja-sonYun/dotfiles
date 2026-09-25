{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.ai-agents.extensions.rules;
  claudeRulesEnabled =
    config.programs.claude-code.mcpServers ? rules
    && !(builtins.elem "rules" (config.programs.claude-code.settings.disabledMcpjsonServers or [ ]));
  codexRulesEnabled =
    (config.programs.codex.settings.mcp_servers or { }) ? rules
    && (config.programs.codex.settings.mcp_servers.rules.enabled or true) != false
    && (config.programs.codex.settings.mcp_servers.rules.disabled or false) != true;
  independentCodexInstances = lib.filterAttrs (
    _: instance: instance.shareWith == null
  ) config.programs.codex.instances;
  requireRules =
    clientName: serverEnabled:
    lib.mapAttrsToList (
      name: instance:
      let
        selection = instance.sync.mcpServers;
      in
      {
        assertion =
          serverEnabled
          && (selection.include == "all" || builtins.elem "rules" selection.include)
          && !(builtins.elem "rules" selection.exclude);
        message = "programs.${clientName}.instances.${name}: shared rules hooks require the enabled rules MCP server in sync.mcpServers.";
      }
    );

  package = pkgs.callPackage ./package.nix { };
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
  rulesFile = pkgs.writeText "ai-agent-rules.json" (builtins.toJSON (lib.listToAttrs rules));
  arguments = [
    "--rules"
    "${rulesFile}"
    "--jev"
    "${pkgs.jev}/bin/jev"
  ]
  ++ lib.optional cfg.debugLog.enable "--debug-log";
  hookCommand = lib.escapeShellArgs ([ "${package}/bin/ai-agent-rules-hook" ] ++ arguments);
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
          description = "Evaluate this rule.";
        };

        title = lib.mkOption {
          type = nonEmptyString;
          default = name;
          description = "Rule display name.";
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
          description = "Case-insensitive file extensions; empty matches all.";
        };

        trigger = lib.mkOption {
          default = { };
          description = "Rule trigger conditions.";
          type = lib.types.submodule {
            options = {
              matcher = lib.mkOption {
                type = lib.types.nullOr nonEmptyString;
                default = null;
                description = "Tool-name Python regex for tool rules.";
              };
              inputFields = lib.mkOption {
                type = lib.types.listOf nonEmptyString;
                default = [ ];
                description = "Input fields to inspect; empty selects all strings.";
              };
              pattern = lib.mkOption {
                type = lib.types.nullOr nonEmptyString;
                default = null;
                description = "Python regex required to match selected input.";
              };
            };
          };
        };

        check = lib.mkOption {
          description = "Exactly one intent or regex check.";
          type = lib.types.submodule {
            options = {
              intent = lib.mkOption {
                type = lib.types.nullOr nonEmptyString;
                default = null;
                description = "Violation criteria and exceptions for Jev.";
              };
              regex = lib.mkOption {
                type = lib.types.nullOr nonEmptyString;
                default = null;
                description = "Python regex matching violations.";
              };
            };
          };
        };

        why = lib.mkOption {
          type = nonEmptyString;
          description = "Why a violation matters.";
        };

        message = lib.mkOption {
          type = nonEmptyString;
          description = "Violation correction guidance.";
        };
      };
    }
  );
in
{
  options.programs.ai-agents.extensions.rules = {
    enable = lib.mkEnableOption "AI agent rule checks";
    debugLog.enable = lib.mkEnableOption "raw rule debug logs with seven-day retention";
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
        description = "Static ${target} rules.";
      }
    );
  };

  config = lib.mkIf (config.programs.ai-agents.enable && cfg.enable) {
    assertions = [
      {
        assertion = builtins.length rules == builtins.length (lib.unique (map (rule: rule.name) rules));
        message = "Rule IDs must be unique across code, tool, and task groups.";
      }
    ]
    ++ lib.concatMap (rule: [
      {
        assertion = (rule.value.check.intent != null) != (rule.value.check.regex != null);
        message = "Rule ${rule.name}: specify exactly one of check.intent and check.regex.";
      }
      {
        assertion =
          rule.value.target == "tool"
          || (rule.value.trigger.matcher == null && rule.value.trigger.inputFields == [ ]);
        message = "Rule ${rule.name}: only tool rules may select tool names or input fields.";
      }
      {
        assertion = rule.value.target == "code" || rule.value.extensions == [ ];
        message = "Rule ${rule.name}: only code rules may specify extensions.";
      }
      {
        assertion = builtins.match "[A-Za-z0-9_-]+" rule.name != null;
        message = "Rule IDs may contain only letters, digits, underscores, and hyphens.";
      }
    ]) rules
    ++ lib.optionals config.programs.claude-code.enable (
      requireRules "claude-code" claudeRulesEnabled config.programs.claude-code.instances
    )
    ++ lib.optionals config.programs.codex.enable (
      requireRules "codex" codexRulesEnabled independentCodexInstances
    );

    programs.ai-agents.hooks =
      lib.mapAttrs
        (_: timeout: [
          {
            hooks = [
              {
                type = "command";
                command = cfg.hookCommand;
                inherit timeout;
              }
            ];
          }
        ])
        {
          SessionStart = 5;
          PreToolUse = 70;
          PostToolUse = 160;
          SessionEnd = 3;
        };

    programs.ai-agents.mcp.servers.rules = {
      command = "${package}/bin/ai-agent-rules-mcp";
      args = arguments;
      env_vars = [
        "TYPESAFE_API_KEY"
        "XDG_CACHE_HOME"
      ];
    };
  };
}
