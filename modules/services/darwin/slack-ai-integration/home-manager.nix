{
  config,
  darwinConfig,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.slackAiIntegration;
  review = cfg.messageReview;
  summary = cfg.threadSummary;
  stateDirectory = "${config.xdg.stateHome}/slack-ai-integration";
  summaryDirectory = "${config.xdg.stateHome}/slack-thread-summary";
  promptsFile = (pkgs.formats.json { }).generate "slack-message-review-prompts.json" review.prompts;
  summaryPromptFile = pkgs.writeText "slack-thread-summary-prompt.txt" summary.prompt;
  launcher = pkgs.writeShellScript "slack-ai-integration-service" ''
    set -e
    exec >>${lib.escapeShellArg "${stateDirectory}/service.log"} 2>&1
    ${lib.optionalString review.enable ''
      ${pkgs.tool.shell.util.shellExports {
        TYPESAFE_API_KEY._secret = review.apiKeyFile;
      }}
      if [ -z "$TYPESAFE_API_KEY" ]; then
        echo "Slack review API key file is missing, unreadable, or empty." >&2
        exit 1
      fi
    ''}

    exec ${pkgs.slack-ai-integration}/bin/slack-ai-integration
  '';
in
{
  options.services.slackAiIntegration = {
    enable = lib.mkEnableOption "Slack AI Tasks, message review, and thread summaries at login";
    codexCommand = lib.mkOption {
      type = lib.types.nullOr lib.types.nonEmptyStr;
      default = null;
      description = "Absolute path to a Codex CLI or instance wrapper, without arguments. Required when enabled.";
    };
    maxConcurrentTasks = lib.mkOption {
      type = lib.types.ints.positive;
      default = 4;
      description = "Maximum running AI tasks across Slack windows. Confirmation waits do not occupy a slot.";
    };
    messageReview = {
      enable = lib.mkEnableOption "Slack pre-send AI review at login";
      ignoreConversations = lib.mkOption {
        type = lib.types.listOf lib.types.nonEmptyStr;
        default = [ ];
        description = "Exact conversation display names that bypass AI review and confirmation before sending.";
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
    threadSummary = {
      enable = lib.mkEnableOption "Slack thread summaries at login";
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
  };

  config = lib.mkMerge [
    {
      launchd.agents.slack-ai-integration = {
        inherit (cfg) enable;
        config = lib.mkIf cfg.enable {
          Label = "com.user.slack-ai-integration";
          ProgramArguments = [ "${launcher}" ];
          EnvironmentVariables = {
            SLACK_AI_STATE_DIRECTORY = stateDirectory;
            SLACK_AI_MAX_CONCURRENT_TASKS = toString cfg.maxConcurrentTasks;
            SLACK_AI_MESSAGE_REVIEW_ENABLED = lib.boolToString review.enable;
            SLACK_AI_THREAD_SUMMARY_ENABLED = lib.boolToString summary.enable;
            SLACK_CODEX_LOG_COMMAND =
              if config.programs.logging.command == null then "" else config.programs.logging.command;
          }
          // lib.optionalAttrs review.enable {
            SLACK_REVIEW_CODEX = if cfg.codexCommand == null then "" else cfg.codexCommand;
            SLACK_REVIEW_MODEL = if review.model == null then "" else review.model;
            SLACK_REVIEW_REASONING_EFFORT =
              if review.reasoningEffort == null then "" else review.reasoningEffort;
            SLACK_REVIEW_SERVICE_TIER = if review.serviceTier == null then "" else review.serviceTier;
            SLACK_REVIEW_JEV = "${pkgs.jev}/bin/jev";
            SLACK_REVIEW_PROMPTS_FILE = "${promptsFile}";
            SLACK_REVIEW_IGNORE_CONVERSATIONS = builtins.toJSON review.ignoreConversations;
            SLACK_REVIEW_STATE_DIRECTORY = stateDirectory;
          }
          // lib.optionalAttrs summary.enable {
            SLACK_THREAD_SUMMARY_CODEX = if cfg.codexCommand == null then "" else cfg.codexCommand;
            SLACK_THREAD_SUMMARY_MODEL = if summary.model == null then "" else summary.model;
            SLACK_THREAD_SUMMARY_PROMPT_FILE = "${summaryPromptFile}";
            SLACK_THREAD_SUMMARY_STATE_DIRECTORY = summaryDirectory;
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
          assertion = review.enable || summary.enable;
          message = "services.slackAiIntegration requires messageReview or threadSummary to be enabled.";
        }
        {
          assertion = !review.enable || review.apiKeyFile != "";
          message = "services.slackAiIntegration.messageReview requires apiKeyFile.";
        }
        {
          assertion = darwinConfig.programs.slack.enable;
          message = "services.slackAiIntegration requires programs.slack.enable in the Darwin configuration.";
        }
        {
          assertion =
            config.programs.codex.enable && cfg.codexCommand != null && lib.hasPrefix "/" cfg.codexCommand;
          message = "services.slackAiIntegration requires programs.codex.enable and an absolute codexCommand path.";
        }
      ];
      home.activation.slackAiIntegrationDirectory =
        lib.hm.dag.entryBetween [ "setupLaunchAgents" ] [ "writeBoundary" ]
          ''
            run ${pkgs.coreutils}/bin/mkdir -p -m 700 ${lib.escapeShellArg stateDirectory}
            ${lib.optionalString summary.enable ''
              run ${pkgs.coreutils}/bin/mkdir -p -m 700 ${lib.escapeShellArg summaryDirectory}
            ''}
          '';
    })
  ];
}
