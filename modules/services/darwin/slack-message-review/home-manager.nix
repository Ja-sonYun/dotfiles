{
  config,
  darwinConfig,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.slackMessageReview;
  stateDirectory = "${config.xdg.stateHome}/slack-message-review";
  agentPackage = config.programs.antigravity-cli.package;
  promptsFile = (pkgs.formats.json { }).generate "slack-message-review-prompts.json" cfg.prompts;
  launcher = pkgs.writeShellScript "slack-message-review-service" ''
    set -e
    ${pkgs.tool.shell.util.shellExports {
      TYPESAFE_API_KEY._secret = cfg.apiKeyFile;
    }}
    if [ -z "$TYPESAFE_API_KEY" ]; then
      echo "Slack review API key file is missing, unreadable, or empty." >&2
      exit 1
    fi

    /usr/bin/open -a ${lib.escapeShellArg cfg.slackApp}
    exec ${pkgs.slack-message-review}/bin/slack-message-review
  '';
in
{
  options.services.slackMessageReview = {
    enable = lib.mkEnableOption "Slack pre-send AI review at login";
    apiKeyFile = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Runtime TypeSafe API key file, required when enabled. Supports shell expansion in agenix paths; the key is read only at service startup.";
    };
    model = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = "gemini-4-argon-medium";
      description = "Antigravity model used for reviews and follow-up requests.";
    };
    slackApp = lib.mkOption {
      type = lib.types.str;
      default = "/Applications/Slack.app";
      description = "Path to the Slack launcher opened before the review controller starts.";
    };
    prompts = {
      classification = lib.mkOption {
        type = lib.types.lines;
        default = ''
          Classify the outgoing Slack message using the supplied conversation context.
          simple_reply: a brief acknowledgment, greeting, or routine question or request.
          link_share: a URL with no text or a short neutral introduction.
          review: a message that would benefit from reviewing clarity, tone, or relevance.
          Choose review when the reply may misunderstand or omit part of a question,
          or when its intended target is unclear. Do not invent missing conversation.
          Do not classify by length alone. Choose review when uncertain.
        '';
        description = "Jev classification instructions; category keys remain fixed.";
      };
      review = lib.mkOption {
        type = lib.types.lines;
        default = ''
          Review the Slack draft for grammar, clarity, tone, and ambiguity.
          In threads, identify the question or request and assess the draft's relevance,
          misunderstandings, and omissions. State when context or the intended target is unclear.
          Claim verification only when supported by sources actually retrieved.
          Do not invent facts, intentions, or commitments.
          Preserve the original language, meaning, names, URLs, and numbers unless asked otherwise.
          Follow the latest revision request and edits. Return the original if no change is needed.
          Do not explain grammar or formatting changes.
        '';
        description = "Antigravity review instructions used for initial reviews and follow-up requests.";
      };
    };
  };

  config = lib.mkMerge [
    {
      launchd.agents.slack-message-review = {
        inherit (cfg) enable;
        config = lib.mkIf cfg.enable {
          Label = "com.user.slack-message-review";
          ProgramArguments = [ "${launcher}" ];
          EnvironmentVariables = {
            SLACK_REVIEW_AGY = if agentPackage == null then "" else "${agentPackage}/bin/agy";
            SLACK_REVIEW_MODEL = cfg.model;
            SLACK_REVIEW_JEV = "${pkgs.jev}/bin/jev";
            SLACK_REVIEW_PROMPTS_FILE = "${promptsFile}";
            SLACK_REVIEW_STATE_DIRECTORY = stateDirectory;
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
          assertion = cfg.apiKeyFile != "";
          message = "services.slackMessageReview requires apiKeyFile.";
        }
        {
          assertion = darwinConfig.programs.slack.enable;
          message = "services.slackMessageReview requires programs.slack.enable in the Darwin configuration.";
        }
        {
          assertion = config.programs.antigravity-cli.enable && agentPackage != null;
          message = "services.slackMessageReview requires an enabled programs.antigravity-cli with a package.";
        }
      ];
      home.activation.slackMessageReviewDirectory =
        lib.hm.dag.entryBetween [ "setupLaunchAgents" ] [ "writeBoundary" ]
          ''
            run ${pkgs.coreutils}/bin/mkdir -p -m 700 ${lib.escapeShellArg stateDirectory}
          '';
    })
  ];
}
