{ config, lib, ... }:

let
  renderBinding = hotkey: command: "${hotkey} : ${command}";
in
{
  options.services.skhd.bindings = lib.mkOption {
    type = lib.types.attrsOf lib.types.str;
    default = { };
    description = "skhd hotkey bindings mapped to shell commands.";
  };

  config.services.skhd.skhdConfig = lib.concatStringsSep "\n" (
    lib.mapAttrsToList renderBinding config.services.skhd.bindings
  );
}
