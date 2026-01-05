{ pkgs, ... }:
let
  originalConfigFile = builtins.readFile ./skhdrc;
  configFileContent = builtins.replaceStrings
    [ "%yabai%" "%skhd%" "%inputSourceSelector%" ]
    [ "${pkgs.yabai}/bin/yabai" "${pkgs.skhd}/bin/skhd" "${pkgs.inputSourceSelector}/bin/InputSourceSelector" ]
    originalConfigFile;
  configFile = pkgs.writeScript "skhdrc" configFileContent;
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
        (toString configFile)
      ];
      KeepAlive = true;
      RunAtLoad = true;
      StandardOutPath = "/tmp/skhd.out.log";
      StandardErrorPath = "/tmp/skhd.err.log";
    };
  };
}
