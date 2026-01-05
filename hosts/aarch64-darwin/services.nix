{ machine, ... }:
{
  imports = (
    if machine == "server" then
      [
        ../../infra/service/aarch64-darwin
      ]
    else
      [ ]
  );
}
