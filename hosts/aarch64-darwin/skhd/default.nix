{ pkgs, lib, config, ... }:
let
  extraPath = pkgs.lib.makeBinPath [
    pkgs.yabai
    pkgs.inputSourceSelector
  ];
  skhdrc = pkgs.replaceVars ./skhdrc {
    inputSourceSelector = "${pkgs.inputSourceSelector}/bin/InputSourceSelector";
  };
in
{
  services.skhd = {
    enable = true;
    skhdConfig = builtins.readFile skhdrc;
  };

  launchd.user.agents.skhd.serviceConfig = {
    StandardOutPath = "/tmp/skhd.out.log";
    StandardErrorPath = "/tmp/skhd.err.log";
    EnvironmentVariables.PATH = lib.mkForce "${pkgs.skhd}/bin:${extraPath}:${config.environment.systemPath}";
  };
}
