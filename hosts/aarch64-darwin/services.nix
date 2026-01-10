{ purpose, ... }:
{
  imports = (
    if purpose == "server" then
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
