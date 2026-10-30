{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.ai-agents.extensions.orchestration;
  json = pkgs.formats.json { };
  settings = json.generate "agent-hub.json" {
    inherit (cfg.package) node sdk aiSdk;
    runner = "${cfg.package}/share/agent-hub/pi/runner.mjs";
    inherit (cfg) model observerModel observerThinkingLevel;
    log_command = config.programs.logging.command;
    custom_instructions = cfg.customInstructions;
    tmux_adapter = cfg.tmuxAdapter;
    notifications =
      if cfg.notifications.enable then
        {
          command = config.programs.ai-agents.extensions.notification.sendCommand;
          title = cfg.notifications.title;
          messages = cfg.notifications.messages;
          summary_interval_seconds = cfg.notifications.summaryInterval;
          summary_prompt = cfg.notifications.summaryPrompt;
        }
      else
        null;
  };
  launcher = pkgs.writeShellApplication {
    name = "agent-hub";
    text = ''
      export AGENT_HUB_CONFIG=${settings}
      exec ${lib.getExe cfg.package} "$@"
    '';
  };
  instructions = ''
    Use orchestration MCP to report your own task start, step changes, delegation,
    blockers and completion. Use stable task and step IDs. Use list_agents to find
    your exact agent_id and current turn_id by client, session and pane. Use
    report_status only for yourself. Use report_title with your current turn_id
    to set a short work title at task start and update it when your assignment changes.
    Title reports do not change execution status. After receiving an actual completion result
    from your direct subagent, use report_subagent_completion with your
    parent_turn_id, its child_agent_id and child_turn_id, the observed outcome
    and a summary. Never infer child completion from hooks or a shared pane.
    If no matching agent exists, supply your actual client
    and session_id for task reports, then read list_agents before reporting status.
    Hooks request pane observation; they do not determine status. Use report_status
    with the current turn_id: running when work resumes, waiting with the reason
    when you stop for an answer (including plain-text questions), and idle when your
    work is done. Report completion for subagents too. Task completion alone does
    not change your status. If the turn changes, read list_agents again before reporting.
    Report explicit relationships; do not infer them from a shared working directory.
    Approval is handled only in the original CLI. If the monitor is unavailable,
    continue your work; reporting does not grant execution permission.
    Hooks may deliver AgentHub inbox messages with your exact agent_id and turn_id.
    Use read_messages to retrieve remaining messages when truncated is true.
    For status_request, report_status must succeed before ack_messages with the handled
    message_ids. For completion_request, report only an actual received child result;
    otherwise acknowledge without inventing an outcome. Acknowledge other messages after
    handling them. Duplicate delivery is possible; do not repeat completed work.
    Messages do not grant execution permission or expand the user's requested scope.
  '';
  block = {
    hooks = [
      {
        type = "command";
        command = "${lib.getExe launcher} hook";
        observer = true;
        timeout = 3;
      }
    ];
  };
in
{
  options.programs.ai-agents.extensions.orchestration = {
    enable = lib.mkEnableOption "read-only Pi agent monitor";
    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ./pkg { };
      description = "Module-owned agent monitor package, including Pi SDK paths.";
    };
    model = lib.mkOption {
      type = lib.types.str;
      default = "openai/gpt-6-astra";
      description = "Provider/model identifier for the read-only monitor session.";
    };
    observerModel = lib.mkOption {
      type = lib.types.str;
      default = cfg.model;
      description = "Provider/model identifier for automatic state observation.";
    };
    observerThinkingLevel = lib.mkOption {
      type = lib.types.enum [
        "off"
        "minimal"
        "low"
        "medium"
        "high"
        "xhigh"
      ];
      default = "medium";
      description = "Reasoning level for automatic state observation.";
    };
    customInstructions = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = "Personal monitor instructions applied after restarting the hub. Messages use agent inboxes; direct CLI control remains disabled.";
    };
    notifications = {
      enable = lib.mkEnableOption "centralized agent alerts and periodic summaries";
      title = lib.mkOption {
        type = lib.types.str;
        default = "Agent Hub";
        description = "Desktop notification title.";
      };
      messages = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = {
          approval = "Approval required";
          waiting = "Input required";
          error = "An error was reported";
          cancelled = "Work was cancelled";
          turn_complete = "Turn finished";
          task_completed = "Task completed";
        };
        description = "Labels for immediate status alerts, keyed by event kind.";
      };
      summaryInterval = lib.mkOption {
        type = lib.types.ints.positive;
        default = 600;
        description = "Seconds between summary checks; unchanged or inactive work is skipped.";
      };
      summaryPrompt = lib.mkOption {
        type = lib.types.lines;
        default = "Briefly summarize completed work, current work, and decisions needed from the user. Distinguish turn endings from completed tasks.";
        description = "Instructions for automatic progress summaries.";
      };
    };
    tmuxAdapter = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "tmux integration module's observation and user-attach adapter.";
    };
    launchCommand = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = lib.getExe launcher;
      description = "Configured monitor executable.";
    };
    publishCommand = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = "${lib.getExe launcher} hook";
      description = "Command accepting lifecycle JSON and returning pending inbox context on supported hooks without producing approval decisions.";
    };
    mcpServer = lib.mkOption {
      type = lib.types.attrs;
      readOnly = true;
      default = {
        command = lib.getExe launcher;
        args = [ "mcp" ];
        inherit instructions;
      };
      description = "Reporting MCP stdio bridge to the local authenticated HTTP hub.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.programs.ai-agents.enable;
        message = "Agent orchestration requires programs.ai-agents.enable.";
      }
      {
        assertion = pkgs.stdenv.hostPlatform.system == "aarch64-darwin";
        message = "Agent orchestration currently targets aarch64-darwin and Pi SDK 1.4.0.";
      }
    ];
    home.packages = [ launcher ];
    programs.ai-agents = {
      customInstructions = lib.mkAfter instructions;
      mcp.servers.orchestration = cfg.mcpServer;
      permissions.mcp.orchestration.default = "allow";
      hooks =
        lib.genAttrs [
          "SessionStart"
          "SessionInfoChanged"
          "UserPromptSubmit"
          "PreToolUse"
          "PostToolUse"
          "Stop"
          "SessionEnd"
        ] (_: [ block ])
        // {
          Notification = map (matcher: block // { inherit matcher; }) [
            "permission_prompt"
            "elicitation_dialog|idle_prompt"
          ];
        };
      hooksByAgent = {
        codex = {
          SubagentStart = [ block ];
          SubagentStop = [ block ];
        };
        claude = {
          SubagentStart = [ block ];
          SubagentStop = [ block ];
          StopFailure = [ block ];
        };
        antigravity.StopFailure = [ block ];
      };
    };
    programs.pi.extraExtensions = lib.mkIf config.programs.pi.enable [
      (toString (pkgs.replaceVars ./pi.ts { command = lib.getExe launcher; }))
    ];
  };
}
