{ pkgs, ... }:

pkgs.rustPlatform.buildRustPackage rec {
  pname = "tmux-menu";
  version = "0.1.28";

  src = pkgs.fetchFromGitHub {
    owner = "Ja-sonYun";
    repo = "tmux-easy-menu";
    rev = "01b110cb596c8bf3e57f2e85f5a25dfc13b019d1";
    hash = "sha256-e+h1djILK7tCWsDUYy2nLNw/7wnOXbzWCUJawgmxd+8=";
  };

  cargoHash = "sha256-s9AOVhKTdm/yQOWlES4YFc1Yj1YcGXPM/oi/zpCGisc=";
  cargoDepsName = pname;
}
