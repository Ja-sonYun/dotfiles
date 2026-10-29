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

    exec ${pkgs.slack-message-review}/bin/slack-message-review
  '';
in
{
  options.services.slackMessageReview = {
    enable = lib.mkEnableOption "Slack pre-send AI review at login";
    codexCommand = lib.mkOption {
      type = lib.types.nullOr lib.types.nonEmptyStr;
      default = null;
      description = "Absolute path to a Codex CLI or instance wrapper, without arguments. Required when enabled.";
    };
    apiKeyFile = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Runtime TypeSafe API key file, required when enabled. Supports shell expansion in agenix paths; the key is read only at service startup.";
    };
    model = lib.mkOption {
      type = lib.types.nullOr lib.types.nonEmptyStr;
      default = null;
      description = "Codex model for reviews and follow-up requests. Null uses the selected Codex configuration.";
    };
    reasoningEffort = lib.mkOption {
      type = lib.types.nullOr lib.types.nonEmptyStr;
      default = null;
      description = "Codex reasoning effort for reviews and follow-up requests. Null uses the selected Codex configuration.";
    };
    serviceTier = lib.mkOption {
      type = lib.types.nullOr lib.types.nonEmptyStr;
      default = null;
      description = "Codex service tier for reviews and follow-up requests. Null uses the selected Codex configuration.";
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
          You must read and apply the communication-coach skill for every review and follow-up request.
          Use its coaching guidance while preserving the required JSON output schema,
          original language, and protected elements.
          Review the Slack draft for grammar, clarity, tone, and ambiguity.
          In threads, identify the question or request and assess the draft's relevance,
          misunderstandings, and omissions. State when context or the intended target is unclear.
          Claim verification only when supported by sources actually retrieved.
          Do not invent facts, intentions, or commitments.
          Preserve the original language, meaning, names, URLs, and numbers unless asked otherwise.
          Follow the latest revision request and edits. Return the original if no change is needed.
          Do not explain grammar or formatting changes.
        '';
        description = "Codex review instructions used for initial reviews and follow-up requests.";
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
            SLACK_CODEX_LOG_COMMAND =
              if config.programs.logging.command == null then "" else config.programs.logging.command;
            SLACK_REVIEW_CODEX = if cfg.codexCommand == null then "" else cfg.codexCommand;
            SLACK_REVIEW_MODEL = if cfg.model == null then "" else cfg.model;
            SLACK_REVIEW_REASONING_EFFORT = if cfg.reasoningEffort == null then "" else cfg.reasoningEffort;
            SLACK_REVIEW_SERVICE_TIER = if cfg.serviceTier == null then "" else cfg.serviceTier;
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
          assertion =
            config.programs.codex.enable && cfg.codexCommand != null && lib.hasPrefix "/" cfg.codexCommand;
          message = "services.slackMessageReview requires programs.codex.enable and an absolute codexCommand path.";
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
