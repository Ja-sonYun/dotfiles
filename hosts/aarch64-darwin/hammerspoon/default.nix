{
  services.hammerspoon = {
    enable = true;
    features = {
      muteMicrophoneOnLock.enable = true;

      applicationInputSources = {
        enable = true;
        rules.Ghostty = "com.apple.keylayout.ABC";
      };
    };
  };
}
