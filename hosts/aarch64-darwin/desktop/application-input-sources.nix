{
  config,
  username,
  ...
}:
{
  assertions = [
    {
      assertion =
        config.services.applicationInputSources.manualSwitch.enable != true
        || config.home-manager.users.${username}.services.seamtype.enable == true;
      message = "The configured manual input source switch requires services.seamtype.enable.";
    }
  ];

  services.applicationInputSources = {
    enable = true;
    manualSwitch = {
      enable = true;
      primarySource = "com.aimdevlee.inputmethod.Seamtype";
      secondarySource = "com.apple.keylayout.ABC";
      alternateSource = "com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese";
    };
    rules = {
      "com.apple.keylayout.ABC" = [
        "Ghostty"
        "Siri"
        "System Settings"
        "Terminal"
        "Code"
        "Xcode"
      ];
      "com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese" = [ "Slack" ];
    };
    defaultSource =
      if config.home-manager.users.${username}.services.seamtype.enable == true then
        "com.aimdevlee.inputmethod.Seamtype"
      else
        null;
  };
}
