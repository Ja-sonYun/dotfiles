{
  username,
  userhome,
  isWsl ? false,
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
      { }
      // (
        if isWsl then
          {
            LD_LIBRARY_PATH = wslNvidiaLib;
          }
        else
          { }
      );

    sessionPath = if isWsl then [ wslNvidiaLib ] else [ ];
  };

  programs.home-manager.enable = true;
}
