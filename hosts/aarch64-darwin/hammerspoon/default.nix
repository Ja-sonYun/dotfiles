{ hostname, ... }:

{
  services.hammerspoon = {
    enable = true;
    features = {
      muteMicrophoneOnLock.enable = true;

      applicationInputSources = {
        enable = true;
        rules.Ghostty = "com.apple.keylayout.ABC";
      };

      meetingRecorder = {
        enable = hostname == "Jays-MacBook-Pro";
        calendarEventBufferMinutes = 4;
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

  programs.spotlightScripts.apps.start-meeting-recording = {
    displayName = "Start Meeting Recording";
    command = [
      "/usr/bin/open"
      "-g"
      "hammerspoon://meeting-recorder-start"
    ];
  };
}
