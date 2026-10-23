{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.logging;
  package = pkgs.callPackage ../../pkgs/cli-tools/dotfiles-log {
    logFile = cfg.file;
    inherit (cfg) maxBytes level socketPath;
  };
  bashPackage = pkgs.callPackage ../../pkgs/cli-tools/dotfiles-log/bash { };
  executable = lib.getExe package;
in
{
  options.programs.logging = {
    enable = lib.mkEnableOption "shared bounded event logging";
    file = lib.mkOption {
      type = lib.types.str;
      default = "${config.xdg.stateHome}/dotfiles/events.jsonl";
      description = "Shared JSONL file. Disabling logging preserves existing records.";
    };
    maxBytes = lib.mkOption {
      type = lib.types.ints.between 1024 2147483647;
      default = 1048576;
      description = "File size limit in bytes, including newlines. Oldest records are discarded.";
    };
    level = lib.mkOption {
      type = lib.types.enum [
        "debug"
        "info"
        "warning"
        "error"
      ];
      default = "info";
      description = "Minimum event severity to retain.";
    };
    socketPath = lib.mkOption {
      type = lib.types.str;
      default = "${config.xdg.cacheHome}/dotfiles-log/socket";
      description = "Absolute Unix stream endpoint shared by all producers; at most 103 bytes.";
    };
    bashLibrary = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      readOnly = true;
      default = if cfg.enable then "${bashPackage}/lib/bash/dotfiles_log.so" else null;
      description = ''
        Loadable builtin for pkgs.bash. After enable -f LIBRARY dotfiles_log,
        call dotfiles_log SOCKET COMPONENT LEVEL EVENT [KEY=VALUE ...].
        Sending never waits or retries; null disables consumer logging.
      '';
    };
    clientSources = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      readOnly = true;
      default = if cfg.enable then ../../pkgs/cli-tools/dotfiles-log/clients else null;
      description = "Reusable native/client.h and go/client.go sources for in-process nonblocking producers.";
    };
    command = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      readOnly = true;
      default = if cfg.enable then lib.getExe package else null;
      description = ''
        Manual socket sender accepting COMPONENT LEVEL EVENT [KEY=VALUE ...].
        Null disables consumer logging. The user service owns the file;
        unavailable or congested endpoints drop events without retrying.
      '';
    };
  };

  config = lib.mkMerge [
    (lib.mkIf pkgs.stdenv.hostPlatform.isDarwin {
      launchd.agents.dotfiles-log = {
        inherit (cfg) enable;
        config = lib.mkIf cfg.enable {
          Label = "com.user.dotfiles-log";
          ProgramArguments = [
            executable
            "serve"
          ];
          RunAtLoad = true;
          KeepAlive = {
            SuccessfulExit = false;
          };
          ThrottleInterval = 10;
          ExitTimeOut = 5;
        };
      };
    })
    (lib.mkIf (cfg.enable && pkgs.stdenv.hostPlatform.isLinux) {
      systemd.user.services.dotfiles-log = {
        Unit.Description = "Bounded shared event logger";
        Service = {
          ExecStart = "${executable} serve";
          Restart = "on-failure";
          RestartSec = "10s";
          TimeoutStopSec = "5s";
        };
        Install.WantedBy = [ "default.target" ];
      };
      home.activation.startDotfilesLogger = lib.hm.dag.entryAfter [ "reloadSystemd" ] ''
        run ${pkgs.systemd}/bin/systemctl --user daemon-reload
        run ${pkgs.systemd}/bin/systemctl --user restart dotfiles-log.service
      '';
    })
    (lib.mkIf cfg.enable {
      assertions = [
        {
          assertion = lib.hasPrefix "/" cfg.socketPath && builtins.stringLength cfg.socketPath <= 103;
          message = "programs.logging.socketPath must be absolute and at most 103 bytes.";
        }
      ];
      home.packages = [ package ];
    })
    (lib.mkIf (!cfg.enable) {
      home.activation.stopDotfilesLogger =
        lib.hm.dag.entryBetween [ "setupLaunchAgents" "reloadSystemd" ] [ "writeBoundary" ]
          ''
            ${
              if pkgs.stdenv.hostPlatform.isDarwin then
                ''
                  if /bin/launchctl print "gui/$(id -u)/com.user.dotfiles-log" >/dev/null 2>&1; then
                    run /bin/launchctl bootout "gui/$(id -u)/com.user.dotfiles-log"
                  fi
                ''
              else
                ''
                  if [ "$(${pkgs.systemd}/bin/systemctl --user show dotfiles-log.service --property=LoadState --value 2>/dev/null)" = loaded ]; then
                    run ${pkgs.systemd}/bin/systemctl --user stop dotfiles-log.service
                  fi
                ''
            }
            run ${executable} cleanup
          '';
    })
  ];
}
