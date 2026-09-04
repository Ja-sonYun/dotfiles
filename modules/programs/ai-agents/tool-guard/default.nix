{
  config,
  lib,
  pkgs,
  ...
}:
let
  clientNames = {
    codex = "Codex";
    claude = "Claude";
    pi = "Pi";
  };
  nonEmptyString = lib.types.addCheck lib.types.str (value: value != "");
  guardType = lib.types.submodule {
    options = {
      matcher = lib.mkOption {
        type = nonEmptyString;
        description = "Regular expression matched against the tool name.";
      };
      approvalToken = lib.mkOption {
        type = nonEmptyString;
        description = "Standalone approval token line; surrounding whitespace, backticks, and backslashes are ignored.";
      };
      inputFields = lib.mkOption {
        type = lib.types.listOf nonEmptyString;
        default = [ ];
        description = "Tool input fields whose string values are matched against `inputPatterns`.";
      };
      inputPatterns = lib.mkOption {
        type = lib.types.listOf nonEmptyString;
        default = [ ];
        description = "Regular expressions that must match an `inputFields` value for the guard to apply.";
      };
      reason = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "Sentence prepended to the denial message.";
      };
    };
  };
  agentGuardsType = lib.types.attrsOf guardType;
  agentGuards = lib.mapAttrs (_: guards: config.programs.ai-agents.toolGuard // guards) {
    codex = config.programs.codex.toolGuard;
    claude = config.programs.claude-code.toolGuard;
    pi = config.programs.pi.toolGuard;
  };
  hasConfiguredGuards = lib.any (guards: guards != { }) (lib.attrValues agentGuards);
  rules = lib.mapAttrs' (client: guards: lib.nameValuePair clientNames.${client} guards) agentGuards;
  rulesFile = pkgs.writeText "ai-agent-tool-guard-rules.json" (builtins.toJSON rules);
  toolGuardCommand =
    event:
    lib.escapeShellArgs [
      "${pkgs.python3}/bin/python"
      "${./tool_guard.py}"
      "--config"
      rulesFile
      "--event"
      event
    ];
  toolGuardHook = event: {
    type = "command";
    command = toolGuardCommand event;
    timeout = 5;
  };
  hooksFor =
    guards:
    let
      matcher = lib.concatMapStringsSep "|" (guard: "(${guard.matcher})") (lib.attrValues guards);
    in
    lib.optionalAttrs (guards != { }) {
      UserPromptSubmit = [
        { hooks = [ (toolGuardHook "UserPromptSubmit") ]; }
      ];
      PreToolUse = [
        {
          inherit matcher;
          hooks = [ (toolGuardHook "PreToolUse") ];
        }
      ];
      SessionEnd = [
        { hooks = [ (toolGuardHook "SessionEnd") ]; }
      ];
    };
in
{
  options.programs = {
    ai-agents.toolGuard = lib.mkOption {
      type = agentGuardsType;
      default = { };
      description = "Named tool guards applied to every enabled AI agent.";
    };
    codex.toolGuard = lib.mkOption {
      type = agentGuardsType;
      default = { };
      description = "Named tool guards applied only to Codex.";
    };
    claude-code.toolGuard = lib.mkOption {
      type = agentGuardsType;
      default = { };
      description = "Named tool guards applied only to Claude Code.";
    };
    pi.toolGuard = lib.mkOption {
      type = agentGuardsType;
      default = { };
      description = "Named tool guards applied only to Pi.";
    };
  };

  config = lib.mkIf (config.programs.ai-agents.enable && hasConfiguredGuards) {
    programs.ai-agents.hooksByAgent = lib.mapAttrs (_: hooksFor) agentGuards;
  };
}
