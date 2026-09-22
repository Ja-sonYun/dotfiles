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
  imports = [
    ./system/nix.nix
    ./services/attic-cache-upload.nix
  ];

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

  programs = {
    home-manager.enable = true;
    loginShell = {
      enable = true;
      path = "${userhome}/.nix-profile/bin/zsh";
    };
  };
}
