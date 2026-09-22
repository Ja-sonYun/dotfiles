{
  services.sessionActions = {
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
  };
}
