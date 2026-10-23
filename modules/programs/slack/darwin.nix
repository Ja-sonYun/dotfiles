{
  config,
  lib,
  pkgs,
  username,
  ...
}:
let
  cfg = config.programs.slack;
in
{
  options.programs.slack = {
    enable = lib.mkEnableOption "the Slack launcher with local debugging";
    autoUpdate = lib.mkOption {
      type = lib.types.nullOr lib.types.bool;
      default = null;
      description = "Slack's built-in AutoUpdate policy. Null leaves the current setting unmanaged; false disables it and true enables it. Homebrew updates are independent.";
    };
  };

  # Homebrew runs first; install the app before Home Manager starts its consumers.
  config.system.activationScripts.postActivation.text = lib.mkBefore ''
    ${pkgs.bash}/bin/bash ${./activate.sh} \
      ${if cfg.enable then "enable" else "disable"} \
      ${if cfg.enable then "${pkgs.slack-launcher}/Applications/Slack.app" else "''"} \
      ${lib.escapeShellArg username} || exit 1
  '';
}
