{
  config,
  darwinConfig,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.slackThreadSummary;
  stateDirectory = "${config.xdg.stateHome}/slack-thread-summary";
  promptFile = pkgs.writeText "slack-thread-summary-prompt.txt" cfg.prompt;
  launcher = pkgs.writeShellScript "slack-thread-summary-service" ''
    set -e
    exec >>${lib.escapeShellArg "${stateDirectory}/service.log"} 2>&1
    exec ${pkgs.slack-thread-summary}/bin/slack-thread-summary
  '';
in
{
  options.services.slackThreadSummary = {
    enable = lib.mkEnableOption "Slack thread summaries at login";
    codexCommand = lib.mkOption {
      type = lib.types.nullOr lib.types.nonEmptyStr;
      default = null;
      description = "Absolute path to a Codex CLI or instance wrapper, without arguments. Required when enabled.";
    };
    model = lib.mkOption {
      type = lib.types.nullOr lib.types.nonEmptyStr;
      default = null;
      description = "Codex model for thread summaries. Null uses the selected Codex configuration.";
    };
    prompt = lib.mkOption {
      type = lib.types.lines;
      default = ''
        Summarize the Slack thread concisely, separating key points, decisions, and remaining actions.
        Account for who said what and how the discussion evolved over time.
        Do not turn proposals, questions, or speculation into confirmed decisions or completed work.
        Do not invent owners, deadlines, decisions, or actions.
        Leave decision or action arrays empty when none are established.
        Preserve the meaning of names, URLs, and numbers in the source.
      '';
      description = "Instructions and output language used for partial and combined thread summaries.";
    };
  };

  config = lib.mkMerge [
    {
      launchd.agents.slack-thread-summary = {
        inherit (cfg) enable;
        config = lib.mkIf cfg.enable {
          Label = "com.user.slack-thread-summary";
          ProgramArguments = [ "${launcher}" ];
          EnvironmentVariables = {
            SLACK_CODEX_LOG_COMMAND =
              if config.programs.logging.command == null then "" else config.programs.logging.command;
            SLACK_THREAD_SUMMARY_CODEX = if cfg.codexCommand == null then "" else cfg.codexCommand;
            SLACK_THREAD_SUMMARY_MODEL = if cfg.model == null then "" else cfg.model;
            SLACK_THREAD_SUMMARY_PROMPT_FILE = "${promptFile}";
            SLACK_THREAD_SUMMARY_STATE_DIRECTORY = stateDirectory;
          };
          RunAtLoad = true;
          KeepAlive = true;
          ThrottleInterval = 10;
          ExitTimeOut = 20;
          LimitLoadToSessionType = "Aqua";
          StandardOutPath = "${stateDirectory}/service.log";
          StandardErrorPath = "${stateDirectory}/service.log";
        };
      };
    }
    (lib.mkIf cfg.enable {
      assertions = [
        {
          assertion = darwinConfig.programs.slack.enable;
          message = "services.slackThreadSummary requires programs.slack.enable in the Darwin configuration.";
        }
        {
          assertion =
            config.programs.codex.enable && cfg.codexCommand != null && lib.hasPrefix "/" cfg.codexCommand;
          message = "services.slackThreadSummary requires programs.codex.enable and an absolute codexCommand path.";
        }
      ];
      home.activation.slackThreadSummaryDirectory =
        lib.hm.dag.entryBetween [ "setupLaunchAgents" ] [ "writeBoundary" ]
          ''
            run ${pkgs.coreutils}/bin/mkdir -p -m 700 ${lib.escapeShellArg stateDirectory}
          '';
    })
  ];
}
