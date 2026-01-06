{ pkgs, ... }:
let
  pathBin = pkgs.lib.makeBinPath [
    pkgs.yabai
    pkgs.skhd
    pkgs.inputSourceSelector
  ];
in
{
  home.packages = [
    pkgs.skhd
  ];

  launchd.agents.skhd = {
    enable = true;
    config = {
      Label = "com.user.skhd";
      ProgramArguments = [
        "${pkgs.skhd}/bin/skhd"
        "-c"
        (toString ./skhdrc)
      ];
      EnvironmentVariables = {
        PATH = "${pathBin}:/usr/bin:/bin:/usr/sbin:/sbin";
      };
      KeepAlive = true;
      RunAtLoad = true;
      StandardOutPath = "/tmp/skhd.out.log";
      StandardErrorPath = "/tmp/skhd.err.log";
    };
  };
}
