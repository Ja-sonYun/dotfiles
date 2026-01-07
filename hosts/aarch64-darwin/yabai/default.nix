{ pkgs, lib, config, ... }:
let
  extraPath = pkgs.lib.makeBinPath [
    pkgs.jq
    pkgs.sketchybar
  ];
in
{
  services.yabai = {
    enable = true;
    enableScriptingAddition = true;
    extraConfig = builtins.readFile ./yabairc;
  };

  launchd.user.agents.yabai.serviceConfig = {
    StandardOutPath = "/tmp/yabai.out.log";
    StandardErrorPath = "/tmp/yabai.err.log";
    EnvironmentVariables.PATH = lib.mkForce "${pkgs.yabai}/bin:${extraPath}:${config.environment.systemPath}";
  };
}
