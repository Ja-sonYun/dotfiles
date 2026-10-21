{ pkgs, ... }:

pkgs.rustPlatform.buildRustPackage rec {
  pname = "tmux-menu";
  version = "0.1.30";

  src = pkgs.fetchFromGitHub {
    owner = "Ja-sonYun";
    repo = "tmux-easy-menu";
    rev = "6e9693b8f6ff2cebd1113190a4e0cd2f7b4a57f0";
    hash = "sha256-MF0rBkBsDlAqYa5WRcw3ZGE8AAsZOiknKQvNWK5OTTo=";
  };

  cargoHash = "sha256-nYbdfviYAJbA8tCEuRNndCbbvu89q9yxW09rTxbABJA=";
  cargoDepsName = pname;
}
