{ pkgs, ... }:

pkgs.rustPlatform.buildRustPackage rec {
  pname = "tmux-menu";
  version = "0.1.28";

  src = pkgs.fetchFromGitHub {
    owner = "Ja-sonYun";
    repo = "tmux-easy-menu";
    rev = "ba3f4373749853c6c50cf9d9fd9389999a018c85";
    hash = "sha256-kA3j30mgzS2Xl6z1EscOsd5UA90MwXBXgQBPhHuHddg=";
  };

  cargoHash = "sha256-s9AOVhKTdm/yQOWlES4YFc1Yj1YcGXPM/oi/zpCGisc=";
  cargoDepsName = pname;
}
