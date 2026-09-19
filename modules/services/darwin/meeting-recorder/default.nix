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
      iconDirectory = "${./misc/status-icons}";
      logPath = "/tmp/meeting-recorder";
      transcriberPath = if cfg.transcription.enable then "${pkgs.whisper-local}/bin/whisper" else null;
      transcription = {
        inherit (cfg.transcription) model language;
      };
    };
    inherit refreshNotification stateNotification;
  };
in
{
  options.services.meetingRecorder = {
    enable = lib.mkEnableOption "meeting audio recording";

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

    transcription = {
      enable = lib.mkEnableOption "local meeting transcription";

      model = lib.mkOption {
        type = lib.types.nullOr lib.types.nonEmptyStr;
        default = null;
        description = "Whisper model file path, or null to use the bundled large-v3 model.";
      };

      language = lib.mkOption {
        type = lib.types.nonEmptyStr;
        default = "auto";
        description = "Whisper language code, or auto for language detection.";
      };
    };
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
      ProgramArguments = [
        (toString (
          pkgs.writeShellScript "audio-process-watcher" ''
            set -e
            umask 077
            for log in /tmp/meeting-recorder.out.log /tmp/meeting-recorder.err.log; do
              if [[ ! -e "$log" && ! -L "$log" ]]; then
                log_tmp=$(/usr/bin/mktemp "$log.XXXXXX")
                log_status=0
                /bin/link "$log_tmp" "$log" || log_status=$?
                /bin/rm -f "$log_tmp"
                if [[ "$log_status" != 0 && ! -e "$log" ]]; then exit 1; fi
              fi
              if [[ -L "$log" || ! -f "$log" || ! -O "$log" ]] || [[ "$(/usr/bin/stat -f %l "$log")" != 1 ]]; then
                printf 'Unsafe log file rejected: %s\n' "$log" >&2
                exit 1
              fi
              /bin/chmod 600 "$log"
            done
            exec ${audioProcessWatcher}/bin/audio-process-watcher \
              >> /tmp/meeting-recorder.out.log 2>> /tmp/meeting-recorder.err.log
          ''
        ))
      ];
      RunAtLoad = true;
      KeepAlive.SuccessfulExit = false;
      ProcessType = "Background";
      Umask = 63;
      ThrottleInterval = 30;
    };
  };
}
