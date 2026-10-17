{ config, lib, ... }:
{
  config = lib.mkIf (config.services.seamtype.enable == true && config.programs.tmux.enable) {
    programs.tmux.extraConfig = ''
      set-option -ag update-environment " __CFBundleIdentifier"
    '';
  };
}
