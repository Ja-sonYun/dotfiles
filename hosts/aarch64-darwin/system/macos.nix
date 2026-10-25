{
  hasTag,
  pkgs,
  userhome,
  username,
  ...
}:

{
  system = {
    stateVersion = 5;
    primaryUser = username;

    keyboard = {
      enableKeyMapping = true;
      remapCapsLockToControl = true;
    };

    defaults = {
      applyToCurrentSession = true;
      menuExtraClock.Show24Hour = true;

      CustomUserPreferences = {
        NSGlobalDomain = {
          NSRecentApplicationsLimit = 0;
          NSRecentDocumentsLimit = 0;
          NSRecentServersLimit = 0;
        };
        "com.apple.dock" = {
          # Require holding Command before the top-right hot corner opens Notification Center.
          "wvous-tr-modifier" = 1048576;
        };
        "com.apple.spaces" = {
          "spans-displays" = false;
        };
        "com.apple.HIToolbox" = {
          AppleGlobalTextInputProperties = {
            TextInputGlobalPropertyPerContextInput = false;
          };
        };
        "kCFPreferencesAnyApplication" = {
          TSMLanguageIndicatorEnabled = false;

        };
      };

      finder = {
        FXRemoveOldTrashItems = true; # Remove items from the Trash after 30 days
        FXPreferredViewStyle = "clmv"; # Column view
        FXEnableExtensionChangeWarning = false;
        AppleShowAllFiles = true;
        AppleShowAllExtensions = true;
      };

      NSGlobalDomain = {
        AppleShowScrollBars = "WhenScrolling";

        InitialKeyRepeat = 17;
        KeyRepeat = 2;

        NSAutomaticSpellingCorrectionEnabled = false;
        NSAutomaticCapitalizationEnabled = false;
        NSAutomaticInlinePredictionEnabled = true;
        NSAutomaticPeriodSubstitutionEnabled = false;
      };

      loginwindow = {
        GuestEnabled = false;
      };

      controlcenter = {
        FocusModes = true;
      };

      WindowManager = {
        EnableStandardClickToShowDesktop = false; # Disable click wallpaper to reveal desktop
        GloballyEnabled = false; # Disable Stage Manager
        StandardHideDesktopIcons = false; # Show items on desktop
      };

      dock = {
        autohide = true;
        mru-spaces = false;
        tilesize = 48;

        persistent-apps = [
          "/System/Applications/Apps.app"
          "/Applications/Safari.app"
          "/System/Applications/Messages.app"
          "/System/Applications/Mail.app"
          "/System/Applications/Maps.app"
          "/System/Applications/Photos.app"
          "/System/Applications/FaceTime.app"
          "/System/Applications/Phone.app"
          "/System/Applications/Calendar.app"
          "/System/Applications/Contacts.app"
          "/System/Applications/Reminders.app"
          "/System/Applications/Notes.app"
          "/System/Applications/TV.app"
          "/System/Applications/Music.app"
          "/System/Applications/Games.app"
          "/System/Applications/App Store.app"
          "/System/Applications/iPhone Mirroring.app"
          "/System/Applications/System Settings.app"
        ];

        persistent-others = [
          {
            folder = {
              path = "${userhome}/Downloads";
              arrangement = "date-added";
              displayas = "stack";
              showas = "fan";
            };
          }
        ];

        # Open Notification Center from the top-right hot corner while holding Command.
        wvous-tr-corner = 12;

        # Keep other hot corners disabled.
        wvous-tl-corner = 1;
        wvous-br-corner = 1;
        wvous-bl-corner = 1;

        show-recents = false;
      };
    };
  };

  power = {
    sleep.computer = if hasTag "server" then "never" else null;
    ac.displaySleep = "never";
    ac.highPerformance = true;
    preventSleep = hasTag "server";
  };

  networking = {
    wakeOnLan.enable = true;
  };

  security.pam.services.sudo_local.touchIdAuth = true;

  programs.zsh = {
    enable = true;
    # Home Manager initializes completion after user fpath entries are added
    enableGlobalCompInit = false;
    enableBashCompletion = false;
  };

  fonts.packages = [
    pkgs.local-fonts
  ];
}
