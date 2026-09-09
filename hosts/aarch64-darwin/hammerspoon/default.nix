{
  services.hammerspoon = {
    enable = true;
    features = {
      desktopNumber.enable = true;

      onLock = {
        enable = true;
        muteMicrophone = true;
        muteAudio = true;
        quitApps = [ "Wallspace" ];
        wallpaper = "Valley";
      };

      onBattery = {
        enable = true;
        quitApps = [ "Wallspace" ];
        wallpaper = "Valley";
      };

      applicationInputSources = {
        enable = true;
        rules.Ghostty = "com.apple.keylayout.ABC";
      };
    };
  };
}
