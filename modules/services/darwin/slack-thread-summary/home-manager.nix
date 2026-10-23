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
  agentPackage = config.programs.antigravity-cli.package;
  promptFile = pkgs.writeText "slack-thread-summary-prompt.txt" cfg.prompt;
  launcher = pkgs.writeShellScript "slack-thread-summary-service" ''
    set -e
    /usr/bin/open -a ${lib.escapeShellArg cfg.slackApp}
    exec ${pkgs.slack-thread-summary}/bin/slack-thread-summary
  '';
in
{
  options.services.slackThreadSummary = {
    enable = lib.mkEnableOption "Slack thread summaries at login";
    model = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = "gemini-4-argon-medium";
      description = "Antigravity model used for thread summaries.";
    };
    slackApp = lib.mkOption {
      type = lib.types.str;
      default = "/Applications/Slack.app";
      description = "Path to the Slack launcher opened before the summary controller starts.";
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
            SLACK_THREAD_SUMMARY_AGY = if agentPackage == null then "" else "${agentPackage}/bin/agy";
            SLACK_THREAD_SUMMARY_MODEL = cfg.model;
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
          assertion = config.programs.antigravity-cli.enable && agentPackage != null;
          message = "services.slackThreadSummary requires an enabled programs.antigravity-cli with a package.";
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
