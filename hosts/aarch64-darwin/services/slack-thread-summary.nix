{ config, ... }:
{
  services.slackThreadSummary = {
    enable = true;
    codexCommand = config.programs.codex.commands.codex-work;
  };
}
