{ pkgs, ... }:

pkgs.rustPlatform.buildRustPackage rec {
  pname = "tmux-menu";
  version = "0.1.31";

  src = pkgs.fetchFromGitHub {
    owner = "Ja-sonYun";
    repo = "tmux-easy-menu";
    rev = "57f82b1e350e9535c74e063fe96d17c331c3d858";
    hash = "sha256-uVbl/G8CDQxlrEVP+1y2G2a4b5buP0cIQ051q7ZYmDA=";
  };

  cargoHash = "sha256-K7bNIbT9NajP/jEJPsgvWqr1OaYXOaeGNbRDpxlsSqQ=";
  cargoDepsName = pname;
}
