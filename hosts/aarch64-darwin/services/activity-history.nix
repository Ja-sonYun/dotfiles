_: {
  services.activityHistory = {
    enable = true;
    startPaused = false;
    excludedApps = [ ];
    capture = {
      intervalSeconds = 30;
      debounceMilliseconds = 700;
      onContextChange = true;
      onClick = true;
      onEnter = true;
    };
    integrations = {
      aiAgents.enable = true;
      tmux.enable = true;
      zsh.enable = true;
    };
  };
}
