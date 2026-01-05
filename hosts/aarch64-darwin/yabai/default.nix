{ pkgs, ... }:
let
  originalConfigFile = builtins.readFile ./yabairc;
  configFileContent =
    builtins.replaceStrings [ "%sketchybar%" ] [ "${pkgs.sketchybar}/bin/sketchybar" ]
      originalConfigFile;
  configFile = pkgs.writeScript "yabairc" configFileContent;
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
        (toString configFile)
      ];
      KeepAlive = true;
      RunAtLoad = true;
      StandardOutPath = "/tmp/yabai.out.log";
      StandardErrorPath = "/tmp/yabai.err.log";
    };
  };
}
