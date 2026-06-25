_:

{
  system.defaults = {
    # Spotlight settings that are not covered by nix-darwin native defaults.
    CustomUserPreferences = {
      # Disable "Help Apple Improve Search" and Siri data sharing.
      "com.apple.assistant.support" = {
        "Search Queries Data Sharing Status" = 2;
        "Siri Data Sharing Opt-In Status" = 2;
      };
    };
  };
}
