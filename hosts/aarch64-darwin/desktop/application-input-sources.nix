{
  config,
  username,
  ...
}:
{
  services.applicationInputSources = {
    enable = true;
    rules = {
      "com.apple.keylayout.ABC" = [
        "Ghostty"
        "System Settings"
        "Terminal"
        "Code"
        "Xcode"
      ];
    };
    defaultSource =
      if config.home-manager.users.${username}.services.seamtype.enable == true then
        "com.aimdevlee.inputmethod.Seamtype"
      else
        null;
  };
}
