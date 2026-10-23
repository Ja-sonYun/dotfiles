{
  services.seamtype = {
    enable = true;
    holdSpace = true;
    settings = {
      japanese = true;
      checkForUpdates = false;
    };
    appDefaults."com.mitchellh.ghostty" = {
      enabled = true;
      conversionThreshold = 0.5;
    };
  };
}
