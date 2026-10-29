{ config, ... }:
{
  services.slackMessageReview = {
    enable = true;
    codexCommand = config.programs.codex.commands.codex-work;
    model = "gpt-6.1-terra";
    reasoningEffort = "low";
    serviceTier = "fast";
  };
}
