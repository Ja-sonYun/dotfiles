{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.navi;
  yamlFormat = pkgs.formats.yaml { };
in
{
  disabledModules = [ "programs/navi.nix" ];

  options.programs.navi = {
    enable = lib.mkEnableOption "navi";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.navi;
      defaultText = lib.literalExpression "pkgs.navi";
      description = "The navi package to use.";
    };

    settings = lib.mkOption {
      inherit (yamlFormat) type;
      default = { };
      description = "Configuration written to ~/.config/navi/config.yaml.";
    };

    enableBashIntegration = lib.mkEnableOption "Bash integration" // {
      default = true;
    };
    enableZshIntegration = lib.mkEnableOption "Zsh integration" // {
      default = true;
    };
    enableFishIntegration = lib.mkEnableOption "Fish integration" // {
      default = true;
    };
  };

  # navi always reads ~/.config/navi; built-in module targets the wrong path on darwin (#6559).
  config = lib.mkIf cfg.enable {
    home.packages = [ cfg.package ];

    programs.bash.initExtra = lib.mkIf cfg.enableBashIntegration ''
      if [[ :$SHELLOPTS: =~ :(vi|emacs): ]]; then
        eval "$(${cfg.package}/bin/navi widget bash)"
      fi
    '';

    programs.zsh.initContent = lib.mkIf cfg.enableZshIntegration ''
      if [[ $options[zle] = on ]]; then
        eval "$(${cfg.package}/bin/navi widget zsh)"
      fi
    '';

    programs.fish.shellInit = lib.mkIf cfg.enableFishIntegration ''
      ${cfg.package}/bin/navi widget fish | source
    '';

    home.file.".config/navi/config.yaml" = lib.mkIf (cfg.settings != { }) {
      source = yamlFormat.generate "navi-config" cfg.settings;
    };
  };
}
