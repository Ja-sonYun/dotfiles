{ pkgs, ... }:
let
  localFonts = pkgs.runCommand "local-fonts" { } ''
    mkdir -p "$out/share/fonts/truetype"
    find "${./ttfs}" -maxdepth 1 -type f \
      \( -iname '*.ttf' -o -iname '*.otf' -o -iname '*.ttc' \) \
      -exec cp {} "$out/share/fonts/truetype/" \;
  '';
in
{
  home.packages = with pkgs; [
    localFonts
    nerd-fonts.fira-code
    nerd-fonts.jetbrains-mono
  ];

  fonts.fontconfig.enable = true;
}
