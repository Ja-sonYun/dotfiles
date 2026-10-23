{
  programs.antigravity-cli = {
    enable = true;

    sync = {
      mcpServers.include = [ ];
      skills.include = [ ];
      agents.include = [ ];
    };

    settings = {
      altScreenMode = "never";
      verbosity = "low";
      showTips = false;
      showFeedbackSurvey = false;
      toolPermission = "request-review";
    };
  };
}
