{
  services.meetingRecorder = {
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
}
