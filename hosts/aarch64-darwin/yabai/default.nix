{ pkgs, ... }:
let
  pathBin = pkgs.lib.makeBinPath [
    pkgs.yabai
    pkgs.jq
    pkgs.sketchybar
  ];
in
{
  home.packages = [
    pkgs.yabai
  ];

  launchd.agents.yabai = {
    enable = true;
    config = {
      Label = "com.user.yabai";
      ProgramArguments = [
        "${pkgs.yabai}/bin/yabai"
        "-c"
        (toString ./yabairc)
      ];
      EnvironmentVariables = {
        PATH = "${pathBin}:/usr/bin:/bin:/usr/sbin:/sbin";
      };
      KeepAlive = true;
      RunAtLoad = true;
      StandardOutPath = "/tmp/yabai.out.log";
      StandardErrorPath = "/tmp/yabai.err.log";
    };
  };
}
