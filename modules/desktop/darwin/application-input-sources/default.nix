{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.applicationInputSources;
  script = pkgs.replaceVars ./script.lua {
    configurationJson = builtins.toJSON (
      {
        rules = lib.concatMapAttrs (source: apps: lib.genAttrs apps (_: source)) cfg.rules;
      }
      // lib.optionalAttrs (cfg.defaultSource != null) {
        inherit (cfg) defaultSource;
      }
      // lib.optionalAttrs (cfg.manualSwitch.enable == true) {
        manualSwitch = {
          inherit (cfg.manualSwitch) primarySource secondarySource alternateSource;
        };
      }
    );
  };
  activateShortcuts = pkgs.writeShellApplication {
    name = "activate-input-source-shortcuts";
    text = builtins.readFile ./activate-shortcuts.sh;
  };
in
{
  options.services.applicationInputSources = {
    enable = lib.mkEnableOption "per-application input sources";

    rules = lib.mkOption {
      type = lib.types.attrsOf (lib.types.listOf lib.types.nonEmptyStr);
      default = { };
      description = ''
        Application names grouped by input source ID. Select the configured source
        when a different regular application becomes active. A Siri rule requests
        its source when com.apple.campo emits a focused-window change or window
        creation event and reports a focused window. Restore the input source
        saved before opening Siri when its window closes or Siri terminates.
        When another regular application becomes active, its rule or defaultSource
        takes precedence over the saved source. Repeated Siri events preserve the
        original source. Other helper applications are ignored. Outside Siri
        restoration, repeated activation of the same regular application is ignored.
      '';
    };

    defaultSource = lib.mkOption {
      type = lib.types.nullOr lib.types.nonEmptyStr;
      default = null;
      description = ''
        Input source ID applied on entry to regular applications without a rule;
        null leaves their input source unchanged.
      '';
    };

    manualSwitch = {
      enable = lib.mkOption {
        type = lib.types.nullOr lib.types.bool;
        default = null;
        description = ''
          Handle Ctrl+Space directly and disable the native Ctrl+Space shortcut.
          False disables this handler and enables the native shortcut; null leaves
          the native setting unmanaged and does not install the handler.
        '';
      };

      primarySource = lib.mkOption {
        type = lib.types.nullOr lib.types.nonEmptyStr;
        default = null;
        description = "Input source selected by one Space press when the primary source is not active. Required when manual switching is enabled.";
      };

      secondarySource = lib.mkOption {
        type = lib.types.nullOr lib.types.nonEmptyStr;
        default = null;
        description = "Input source selected by one Space press when the primary source is active. Required when manual switching is enabled.";
      };

      alternateSource = lib.mkOption {
        type = lib.types.nullOr lib.types.nonEmptyStr;
        default = null;
        description = "Input source selected by two or more Space presses while Control remains held. Selection occurs on Control release. Required when manual switching is enabled.";
      };
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      assertions = [
        {
          assertion = config.services.hammerspoon.enable;
          message = "services.applicationInputSources requires services.hammerspoon.enable.";
        }
      ];
      services.hammerspoon = {
        enable = lib.mkDefault true;
        scripts = [
          {
            name = "application-input-sources.lua";
            path = script;
          }
        ];
      };
    })
    (lib.mkIf (cfg.manualSwitch.enable == true) {
      assertions = [
        {
          assertion = cfg.enable;
          message = "services.applicationInputSources.manualSwitch requires services.applicationInputSources.enable.";
        }
        {
          assertion = lib.all (source: source != null) [
            cfg.manualSwitch.primarySource
            cfg.manualSwitch.secondarySource
            cfg.manualSwitch.alternateSource
          ];
          message = "services.applicationInputSources.manualSwitch requires primarySource, secondarySource and alternateSource.";
        }
      ];
    })
    (lib.mkIf (cfg.manualSwitch.enable != null) {
      assertions = [
        {
          assertion = config.system.defaults.applyToCurrentSession;
          message = "services.applicationInputSources.manualSwitch requires system.defaults.applyToCurrentSession.";
        }
      ];

      system = {
        requiresPrimaryUser = [ "services.applicationInputSources.manualSwitch" ];
        defaults.applyToCurrentSession = lib.mkDefault true;

        # Apply before session-settings refreshes the current session at order 1400.
        activationScripts.postActivation.text = lib.mkOrder 1300 ''
          input_source_uid=$(/usr/bin/id -u -- ${lib.escapeShellArg config.system.primaryUser})
          /bin/launchctl asuser "$input_source_uid" /usr/bin/sudo --user=${lib.escapeShellArg config.system.primaryUser} -- \
            ${activateShortcuts}/bin/activate-input-source-shortcuts ${
              if cfg.manualSwitch.enable == true then "false" else "true"
            } || exit $?
        '';
      };
    })
  ];
}
