{
  hasTag,
  username,
  userhome,
  ...
}:
let
  wslNvidiaLib = "/usr/lib/wsl/lib";
in
{
  home = {
    inherit username;
    homeDirectory = userhome;
    stateVersion = "26.05";

    sessionVariables =
      if hasTag "wsl" && hasTag "gpu" then
        {
          LD_LIBRARY_PATH = wslNvidiaLib;
        }
      else
        { };

    sessionPath = if hasTag "wsl" && hasTag "gpu" then [ wslNvidiaLib ] else [ ];
  };

  programs.home-manager.enable = true;
}
