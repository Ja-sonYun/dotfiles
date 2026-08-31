{
  hasTag,
  lib,
  ...
}:
{
  imports = lib.optionals (hasTag "ai") [ ./agent ] ++ [
    ./monitor
    ./popup
    ./shell
    ./watch
  ];
}
