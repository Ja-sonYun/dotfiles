{ pkgs, ... }:

pkgs.rustPlatform.buildRustPackage rec {
  pname = "tmux-menu";
  version = "0.1.28";

  src = pkgs.fetchFromGitHub {
    owner = "Ja-sonYun";
    repo = "tmux-easy-menu";
    rev = "34af6476f8a7252478b2a1ee41e4121c3e28839d";
    hash = "sha256-9JEG/4dgctsChcyTIm+Mlvgv0GGoTbBadZIjipAwXlk=";
  };

  cargoHash = "sha256-s9AOVhKTdm/yQOWlES4YFc1Yj1YcGXPM/oi/zpCGisc=";
  cargoDepsName = pname;
}
