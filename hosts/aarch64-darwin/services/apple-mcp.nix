{
  config,
  hostname,
  username,
  ...
}:
{
  services = {
    apple-mcp = {
      enable = hostname == "Jays-MacBook-Pro-Server";
      tokenFile = config.home-manager.users.${username}.age.secrets."capi-key".path;
      allowedHosts = [ "apple.test0.zip" ];
      allowedOrigins = [ "https://apple.test0.zip" ];
    };
    apple-calendar.enable = hostname == "Jays-MacBook-Pro-Server";
    apple-reminders = {
      enable = hostname == "Jays-MacBook-Pro-Server";
      tokenFile = config.home-manager.users.${username}.age.secrets."capi-key".path;
    };
  };
}
