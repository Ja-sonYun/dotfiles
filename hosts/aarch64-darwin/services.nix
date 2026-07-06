{
  hostname,
  infraSrc,
  ...
}:
{
  imports =
    if hostname == "Jays-MacBook-Pro-Server" then
      [
        ./sharing.nix
        (infraSrc + "/services/Jays-MacBook-Pro-Server")
      ]
    else
      [
        ./yabai
        ./skhd
      ];
}
