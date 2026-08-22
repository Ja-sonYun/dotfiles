{ config, lib, ... }:

let
  cfg = config.services.skhd;
  renderBinding = hotkey: command: "${hotkey} : ${command}";
in
{
  options.services.skhd.bindings = lib.mkOption {
    type = lib.types.attrsOf lib.types.str;
    default = { };
    description = "skhd hotkey bindings mapped to shell commands.";
  };

  config = lib.mkMerge [
    {
      services.skhd.skhdConfig = lib.concatStringsSep "\n" (
        lib.mapAttrsToList renderBinding cfg.bindings
      );
    }
    (lib.mkIf cfg.enable {
      launchd.user.agents.skhd.serviceConfig = {
        StandardOutPath = "/tmp/skhd.out.log";
        StandardErrorPath = "/tmp/skhd.err.log";
      };
    })
  ];
}
