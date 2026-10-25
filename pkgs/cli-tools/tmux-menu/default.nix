{ pkgs, ... }:

pkgs.rustPlatform.buildRustPackage rec {
  pname = "tmux-menu";
  version = "0.1.32";

  src = pkgs.fetchFromGitHub {
    owner = "Ja-sonYun";
    repo = "tmux-easy-menu";
    rev = "826a259cb7ddd521f44ce2638bb2ea7234992fbe";
    hash = "sha256-WEa0l1M6YWF89zPU71lrGviFmTKrP44BNrW3etpeaZQ=";
  };

  cargoHash = "sha256-xOXFPhDCoHtqFA/fDGI+dL8cSaCaDWQG9TKqCRr3tIw=";
  cargoDepsName = pname;
}
