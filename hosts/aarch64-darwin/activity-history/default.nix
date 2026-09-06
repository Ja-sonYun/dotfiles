_: {
  services.activityHistory = {
    enable = true;
    startPaused = false;
    excludedApps = [ ];
    capture = {
      allowedApps = [
        "com.apple.Safari"
        "notion.id"
        "com.tinyspeck.slackmacgap"
        "com.google.Chrome"
      ];
      intervalSeconds = 30;
      debounceMilliseconds = 700;
      onContextChange = true;
      onClick = true;
      onEnter = true;
    };
    integrations = {
      tmux.enable = true;
      zsh.enable = true;
    };
  };
}
