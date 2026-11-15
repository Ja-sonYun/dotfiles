{ config, ... }:
{
  services.slackAiIntegration = {
    enable = true;
    codexCommand = config.programs.codex.commands.codex-work;
    maxConcurrentTasks = 4;
    messageReview = {
      enable = true;
      model = "gpt-6.1-terra";
      reasoningEffort = "low";
      serviceTier = "fast";
    };
    threadSummary.enable = true;
  };
}
