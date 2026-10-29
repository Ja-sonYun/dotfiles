{
  programs.antigravity-cli = {
    enable = true;

    sync = {
      mcpServers.include = [ ];
      skills.include = [ ];
      agents.include = [ ];
    };

    keybindings = {
      "navigation.page_up" = [ ];
      "navigation.page_down" = [ ];
      "navigation.half_page_up" = [
        "pgup"
        "shift+up"
      ];
      "navigation.half_page_down" = [
        "pgdown"
        "shift+down"
      ];
    };

    settings = {
      altScreenMode = "always";
      verbosity = "low";
      showTips = false;
      showFeedbackSurvey = false;
      toolPermission = "request-review";
    };
  };
}
