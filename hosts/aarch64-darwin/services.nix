{
  hasTag,
  hostname,
  infraSrc,
  lib,
  ...
}:
{
  imports =
    lib.optionals (hasTag "gui") [
      ./yabai
      ./skhd
    ]
    ++ lib.optionals (hasTag "server") [
      ./sharing.nix
    ]
    ++ lib.optionals (hostname == "Jays-MacBook-Pro-Server") [
      (infraSrc + "/services/Jays-MacBook-Pro-Server")
    ];
}
