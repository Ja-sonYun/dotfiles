{ configDir
, hostname
, pkgs
, userhome
, username
, ...
}:

let
  powerAdapterScript = ''
    # Keep the display on while connected to a power adapter.
    /usr/bin/pmset -c displaysleep 0

    if /usr/bin/pmset -g cap | /usr/bin/grep -q highpowermode; then
      # Use High Power Mode on adapters that support it.
      /usr/bin/pmset -c powermode 2
    fi
  '';

  serverActiveScript =
    if hostname == "Jays-MacBook-Pro-Server" then
      ''
        # Keep the server awake even when idle.
        pmset -a sleep 0
        pmset -a disablesleep 1
      ''
    else
      '''';
in
{
  # macOS system configuration.
  # Options: https://daiderd.com/nix-darwin/manual/index.html#sec-options
  system = {
    stateVersion = 5;
    primaryUser = username;

    keyboard = {
      enableKeyMapping = true;
      remapCapsLockToControl = true;
    };

    defaults = {
      menuExtraClock.Show24Hour = true; # show 24 hour clock

      CustomUserPreferences = {
        "com.apple.dock" = {
          # Require holding Command before the top-right hot corner opens Notification Center.
          "wvous-tr-modifier" = 1048576;
        };
      };

      finder = {
        FXRemoveOldTrashItems = true; # Remove items from the Trash after 30 days
        FXPreferredViewStyle = "clmv"; # Column view
        FXEnableExtensionChangeWarning = false; # Disable warning when changing file extension
        AppleShowAllFiles = true; # Show hidden files
        AppleShowAllExtensions = true; # Show all file extensions
      };

      NSGlobalDomain = {
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
      };

      dock = {
        autohide = true;
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

        show-recents = false; # Do not show recent applications in Dock
      };
    };

    activationScripts.postActivation.text = ''
      set -euo pipefail

      # activateSettings -u will reload the settings from the database and apply them to the current session,
      # so we do not need to logout and login again to make the changes take effect.
      /System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings -u

      ${powerAdapterScript}

      ${serverActiveScript}
    '';
  };

  networking = {
    wakeOnLan.enable = true;
  };

  # Add ability to used TouchID for sudo authentication
  security.pam.services.sudo_local.touchIdAuth = true;

  # Create /etc/zshrc that loads the nix-darwin environment.
  # this is required if you want to use darwin's default shell - zsh
  programs.zsh = {
    enable = true;
    # Home Manager initializes completion after user fpath entries are added
    enableGlobalCompInit = false;
    enableBashCompletion = false;
  };

  # Further configurations are defined in ./shell/system.nix
  fonts.packages = [
    "${configDir}/misc/fonts"
  ];
}
