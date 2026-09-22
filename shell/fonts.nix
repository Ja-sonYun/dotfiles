{ pkgs, ... }:
{
  home.packages = with pkgs; [
    local-fonts
    nerd-fonts.fira-code
    nerd-fonts.jetbrains-mono
  ];

  fonts.fontconfig.enable = true;
}
