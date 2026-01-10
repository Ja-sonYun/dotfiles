{ configDir
, purpose
, username
, ...
}:

let
  serverActiveScript =
    if purpose == "server" then
      ''
        pmset -a sleep 0
        pmset -a disablesleep 1
      ''
    else
      '''';
in

###################################################################################
  #
  #  macOS's System configuration
  #
  #  All the configuration options are documented here:
  #    https://daiderd.com/nix-darwin/manual/index.html#sec-options
  #
  ###################################################################################
{
  system = {
    stateVersion = 5;
    primaryUser = username;

    # activationScripts are executed every time you boot the system or run `nixos-rebuild` / `darwin-rebuild`.
    activationScripts.reloadMacSettings.text = ''
      # activateSettings -u will reload the settings from the database and apply them to the current session,
      # so we do not need to logout and login again to make the changes take effect.
      /System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings -u
    '';

    keyboard = {
      enableKeyMapping = true;
      remapCapsLockToControl = true;
    };

    defaults = {
      menuExtraClock.Show24Hour = true; # show 24 hour clock

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
      };

      loginwindow = {
        GuestEnabled = false;
      };

      controlcenter = {
        FocusModes = true;
        Sound = true;
      };

      dock = {
        autohide = true;

        # wvous-tr-corner = 12; # Show notification center
        # Disable hot corner
        wvous-tr-corner = 1; # Show notification center
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
  programs.zsh.enable = true;

  # Further configurations are defined in ./shell/system.nix
  fonts.packages = [
    "${configDir}/misc/fonts"
  ];
}
