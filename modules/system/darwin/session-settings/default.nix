{ config, lib, ... }:
{
  options.system.defaults.applyToCurrentSession = lib.mkEnableOption "applying defaults to the current session during activation";

  config = lib.mkIf config.system.defaults.applyToCurrentSession {
    # Run after defaults are written and before menu extras are reloaded.
    system.activationScripts.postActivation.text = lib.mkOrder 1400 ''
      /System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings -u || exit $?
    '';
  };
}
