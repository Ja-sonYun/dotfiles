{ paths, pkgs, ... }:
{
  home.packages = [ pkgs.templates-cli ];
  home.sessionVariables.FLAKE_TEMPLATES_DIR = "${paths.dotfiles}/templates";
  programs.zsh-customize.fpath = [ "${pkgs.templates-cli}/share/zsh/site-functions" ];
}
