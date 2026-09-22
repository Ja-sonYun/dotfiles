{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.power;
  managed = cfg.ac.displaySleep != null || cfg.ac.highPerformance != null || cfg.preventSleep != null;
  applyPower = pkgs.writeShellScript "apply-power-settings" ''
    set -euo pipefail

    ${lib.optionalString (cfg.ac.displaySleep != null) ''
      /usr/bin/pmset -c displaysleep ${
        if cfg.ac.displaySleep == "never" then "0" else toString cfg.ac.displaySleep
      }
    ''}
    ${lib.optionalString (cfg.ac.highPerformance != null) ''
      capabilities=$(/usr/bin/pmset -g cap)
      if /usr/bin/grep -q highpowermode <<< "$capabilities"; then
        /usr/bin/pmset -c powermode ${if cfg.ac.highPerformance then "2" else "0"}
      fi
    ''}
    ${lib.optionalString (cfg.preventSleep != null) ''
      /usr/bin/pmset -a disablesleep ${if cfg.preventSleep then "1" else "0"}
    ''}
  '';
in
{
  options.power = {
    ac.displaySleep = lib.mkOption {
      type = lib.types.nullOr (lib.types.either lib.types.ints.positive (lib.types.enum [ "never" ]));
      default = null;
      description = "Display sleep timeout in minutes on AC power, never, or null to leave unmanaged.";
    };
    ac.highPerformance = lib.mkOption {
      type = lib.types.nullOr lib.types.bool;
      default = null;
      description = "Use High Power Mode on supported adapters; false selects automatic mode, null leaves it unmanaged.";
    };
    preventSleep = lib.mkOption {
      type = lib.types.nullOr lib.types.bool;
      default = null;
      description = "Prevent system sleep; false allows manual sleep without changing idle timers, null leaves it unmanaged.";
    };
  };

  config = lib.mkIf managed {
    system.activationScripts.postActivation.text = ''
      ${applyPower} || exit $?
    '';
  };
}
