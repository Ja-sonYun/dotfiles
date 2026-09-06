{
  config,
  lib,
  pkgs,
  username,
  userhome,
  ...
}:
let
  cfg = config.services.meetingRecorder;
  audioProcessWatcher = pkgs.callPackage ./pkgs/audio-process-watcher { };
  calendarEventQuery = pkgs.callPackage ./pkgs/calendar-event-query { };
  meetingRecorder = pkgs.callPackage ./pkgs/meeting-recorder { };
  helpersDirectory = "${userhome}/.local/libexec/hammerspoon";
  stateNotification = "com.jaykuroyanagi.audio-process-watcher.state";
  refreshNotification = "com.jaykuroyanagi.audio-process-watcher.refresh";
  calendarResponseNotification = "com.jaykuroyanagi.calendar-event-query.response";
  recorderStateNotification = "com.jaykuroyanagi.meeting-recorder.state";
  recorderStopNotification = "com.jaykuroyanagi.meeting-recorder.stop";
  script = pkgs.replaceVars ./recorder.lua {
    configJson = builtins.toJSON {
      inherit (cfg)
        browserRules
        browserQueryTimeoutSeconds
        calendarEventBufferMinutes
        calendarQueryTimeoutSeconds
        outputDirectory
        startTimeoutSeconds
        stopDelaySeconds
        ;
      calendarQueryAppPath = "${helpersDirectory}/Calendar Event Query.app";
      inherit
        calendarResponseNotification
        recorderStateNotification
        recorderStopNotification
        ;
      recorderAppPath = "${helpersDirectory}/Meeting Recorder.app";
      transcriberPath = if cfg.transcription.enable then "${pkgs.whisper-local}/bin/whisper" else null;
    };
    inherit refreshNotification stateNotification;
  };
in
{
  options.services.meetingRecorder = {
    enable = lib.mkEnableOption "meeting audio recording";

    browserRules = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            host = lib.mkOption {
              type = lib.types.nonEmptyStr;
            };

            includeSubdomains = lib.mkOption {
              type = lib.types.bool;
              default = false;
            };

            pathPatterns = lib.mkOption {
              type = lib.types.listOf lib.types.nonEmptyStr;
            };
          };
        }
      );
      default = [ ];
      description = "Host and Lua path patterns for meeting URLs.";
    };

    browserQueryTimeoutSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 3;
      description = "Seconds to wait for a browser URL query.";
    };

    calendarEventBufferMinutes = lib.mkOption {
      type = lib.types.ints.positive;
      default = 4;
      description = "Minutes around meeting detection used to find calendar events.";
    };

    calendarQueryTimeoutSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 60;
      description = "Seconds to wait for a Calendar query.";
    };

    outputDirectory = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = "${userhome}/Documents/Meetings";
      description = "Directory for meeting recordings.";
    };

    startTimeoutSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 60;
      description = "Seconds to wait for the recorder capture to start.";
    };

    stopDelaySeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 180;
      description = "Seconds to keep recording while waiting for a meeting reconnect.";
    };

    transcription.enable = lib.mkEnableOption "local meeting transcription";
  };

  config = lib.mkIf cfg.enable {
    services.codeSigning.targets = {
      calendar-event-query = {
        source = "${calendarEventQuery}/Applications/Calendar Event Query.app";
        target = "${helpersDirectory}/Calendar Event Query.app";
      };

      meeting-recorder = {
        source = "${meetingRecorder}/Applications/Meeting Recorder.app";
        target = "${helpersDirectory}/Meeting Recorder.app";
      };
    };

    services.hammerspoon = {
      enable = lib.mkDefault true;
      preparedScripts = [
        {
          name = "meeting-recorder.lua";
          path = script;
        }
      ];
    };

    programs.spotlightScripts = {
      enable = lib.mkDefault true;
      apps.start-meeting-recording = {
        displayName = "Start Meeting Recording";
        icon = ./misc/icon.svg;
        command = [
          "/usr/bin/open"
          "-g"
          "hammerspoon://meeting-recorder-start"
        ];
      };
    };

    home-manager.users.${username}.home.packages = [ pkgs.whisper-local ];

    launchd.user.agents.hammerspoon-audio-process-watcher.serviceConfig = {
      ProgramArguments = [ "${audioProcessWatcher}/bin/audio-process-watcher" ];
      RunAtLoad = true;
      KeepAlive.SuccessfulExit = false;
      ProcessType = "Background";
      StandardErrorPath = "${userhome}/Library/Logs/audio-process-watcher.log";
      ThrottleInterval = 30;
    };
  };
}
