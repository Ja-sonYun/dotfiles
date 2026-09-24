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

        trigger = lib.mkOption {
          default = { };
          description = "Optional conditions that select when to evaluate this rule.";
          type = lib.types.submodule {
            options = {
              matcher = lib.mkOption {
                type = lib.types.nullOr nonEmptyString;
                default = null;
                description = "Python regular expression matching tool names; only for tool rules.";
              };
              inputFields = lib.mkOption {
                type = lib.types.listOf nonEmptyString;
                default = [ ];
                description = "Nested tool input fields to inspect, or all strings when empty.";
              };
              pattern = lib.mkOption {
                type = lib.types.nullOr nonEmptyString;
                default = null;
                description = "Python regular expression that selected input must match.";
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
                description = "Independent violation criteria and exceptions sent to Jev.";
              };
              regex = lib.mkOption {
                type = lib.types.nullOr nonEmptyString;
                default = null;
                description = "Python regular expression whose match is a violation.";
              };
            };
          };
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
  options.programs.ai-agents.extensions.rules = {
    enable = lib.mkEnableOption "Rules and inspection tools, requiring the rules MCP server in every active Claude Code and Codex instance";
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
        description = "Static ${target} rules evaluated by their check; MCP cannot modify them.";
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
