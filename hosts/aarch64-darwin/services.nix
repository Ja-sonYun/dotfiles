{ hostname, infraSrc, ... }:
{
  imports = (
    if hostname == "Jasons-MacBook-Server" then
      [
        (infraSrc + "/service/Jasons-MacBook-Server")
      ]
    else
      [
        ./yabai
        ./skhd
        ./sketchybar
      ]
  );
}
