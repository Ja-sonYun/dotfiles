{
  config,
  lib,
  ...
}:
let
  cfg = config.programs.claude-desktop;
in
{
  options.programs.claude-desktop = {
    enable = lib.mkEnableOption "Claude Desktop settings management";
    settings = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      description = "Claude Desktop settings.";
    };
  };

  config = lib.mkIf cfg.enable {
    home.file."Library/Application Support/Claude/claude_desktop_config.json" = {
      force = true;
      text = builtins.toJSON cfg.settings;
    };
  };
}
