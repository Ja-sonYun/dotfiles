_: {
  services.menubar = {
    hideSpotlight = true;
    weather.enable = true;
  };

  system = {
    defaults = {
      controlcenter = {
        AirDrop = false;
        Bluetooth = false;
        Display = false;
        NowPlaying = false;
        Sound = true;
      };

      CustomUserPreferences = {
        "com.apple.controlcenter" = {
          # Keep standard Control Center menu bar items visible without changing their order.
          "NSStatusItem VisibleCC AirDrop" = 0;
          "NSStatusItem VisibleCC Battery" = 1;
          "NSStatusItem VisibleCC BentoBox-0" = 1;
          "NSStatusItem VisibleCC Clock" = 1;
          "NSStatusItem VisibleCC FocusModes" = 1;
          "NSStatusItem VisibleCC Sound" = 1;
          "NSStatusItem VisibleCC WiFi" = 1;
        };

        "com.apple.TextInputMenuAgent" = {
          # Keep the input source menu visible.
          "NSStatusItem VisibleCC Item-0" = 1;
        };
      };
    };
  };
}
