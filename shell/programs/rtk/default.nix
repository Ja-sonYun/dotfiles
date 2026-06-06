{ pkgs, ... }:

let
  rtkVersion = "0.38.0";

  claudeRtkAwareness = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/rtk-ai/rtk/v${rtkVersion}/hooks/claude/rtk-awareness.md";
    hash = "sha256-n+AH2dfKeQ81tIvRIJnhs6Ha4FyvKW26PdviYh3bAtw=";
  };

  codexRtkAwareness = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/rtk-ai/rtk/v${rtkVersion}/hooks/codex/rtk-awareness.md";
    hash = "sha256-ScNowwLG9j0In0wQhbJC/FD+Is5bw02tpkeAgwAOfG8=";
  };
in
{
  home.packages = [
    pkgs.rtk
  ];

  home.file = {
    ".claude/RTK.md".source = claudeRtkAwareness;
    ".codex-cli/RTK.md".source = codexRtkAwareness;
  };
}
