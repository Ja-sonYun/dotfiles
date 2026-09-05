{ hasTag, lib, ... }:
{
  services.hammerspoon = {
    enable = true;
    features = {
      muteMicrophoneOnLock.enable = true;

      applicationInputSources = {
        enable = true;
        rules.Ghostty = "com.apple.keylayout.ABC";
      };

      meetingRecorder = lib.mkIf (hasTag "meeting") {
        enable = true;
        outputDirectory = "/Users/jaykuroyanagi/Library/Mobile Documents/iCloud~md~obsidian/Documents/Life/Meetings";
        calendarEventBufferMinutes = 4;
        transcription.enable = true;
        browserRules = [
          {
            host = "meet.google.com";
            pathPatterns = [
              "^/[a-z][a-z][a-z]%-[a-z][a-z][a-z][a-z]%-[a-z][a-z][a-z]$"
              "^/lookup/"
            ];
          }
          {
            host = "zoom.us";
            includeSubdomains = true;
            pathPatterns = [
              "^/j/"
              "^/my/"
              "^/wc/"
            ];
          }
          {
            host = "teams.microsoft.com";
            pathPatterns = [
              "^/l/meetup%-join/"
              "^/meet/"
            ];
          }
        ];
      };
    };
  };

  programs.spotlightScripts.apps.start-meeting-recording = lib.mkIf (hasTag "meeting") {
    displayName = "Start Meeting Recording";
    command = [
      "/usr/bin/open"
      "-g"
      "hammerspoon://meeting-recorder-start"
    ];
  };
}
