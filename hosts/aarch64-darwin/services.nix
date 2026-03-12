{ hostname, ... }:
{
  imports = (
    if hostname == "Jasons-MacBook-Server" then
      [
        ../../infra/service/Jasons-MacBook-Server
      ]
    else
      [
        ./yabai
        ./skhd
        ./sketchybar
      ]
  );
}
