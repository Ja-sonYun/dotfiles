{
  aoe,
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.aoe;
  tomlFormat = pkgs.formats.toml { };
in
{
  options.programs.aoe = {
    enable = lib.mkEnableOption "Agent of Empires";

    package = lib.mkOption {
      type = lib.types.package;
      default = aoe.packages.${pkgs.stdenv.hostPlatform.system}.default;
      description = "Agent of Empires package to install.";
    };

    settings = lib.mkOption {
      inherit (tomlFormat) type;
      default = { };
      description = "Settings written to ~/.agent-of-empires/config.toml.";
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ cfg.package ];

    home.file.".agent-of-empires/config.toml".source =
      tomlFormat.generate "agent-of-empires-config.toml" cfg.settings;
  };
}
