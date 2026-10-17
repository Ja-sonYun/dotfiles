{
  services.seamtype = {
    enable = true;
    settings = {
      japanese = true;
      checkForUpdates = false;
    };
    appDefaults."com.mitchellh.ghostty" = {
      enabled = true;
      conversionThreshold = 0.5;
      holdSpace = false;
    };
  };
}
