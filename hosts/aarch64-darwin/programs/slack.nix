{ config, ... }:
{
  programs.slack = {
    enable = true;
    autoUpdate = false;
  };

  system.defaults.dock.persistent-apps = [
    (
      if config.programs.slack.enable then "/Applications/Slack.app" else "/Applications/_Slack/Slack.app"
    )
  ];
}
