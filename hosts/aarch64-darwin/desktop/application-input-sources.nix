{
  config,
  username,
  ...
}:
{
  services.applicationInputSources = {
    enable = true;
    rules = {
      "com.apple.keylayout.ABC" = [ "Ghostty" ];
    };
    defaultSource =
      if config.home-manager.users.${username}.services.seamtype.enable == true then
        "com.aimdevlee.inputmethod.Seamtype"
      else
        null;
  };
}
