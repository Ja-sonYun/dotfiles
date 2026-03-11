{ hostname, ... }:
{
  imports = (
    if hostname == "Jasons-MacBook-Server" then
      [
        ../../infra/service/aarch64-darwin
      ]
    else
      [
        ./yabai
        ./skhd
        ./sketchybar
      ]
  );
}
