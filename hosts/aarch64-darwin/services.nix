{ hostname, infraSrc, ... }:
{
  imports = (
    if hostname == "Jays-MacBook-Pro-Server" then
      [
        ./sharing.nix
        (infraSrc + "/service/Jays-MacBook-Pro-Server")
      ]
    else
      [
        ./yabai
        ./skhd
        ./sketchybar
      ]
  );
}
