{ hostname, purpose, ... }:
{
  imports =
    if purpose == "server" && hostname == "Jasonyun-wsl-server" then
      [
        ../../infra/service/Jasonyun-wsl-server
      ]
    else
      [ ];
}
