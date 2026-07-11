{ pkgs, ... }:

pkgs.rustPlatform.buildRustPackage rec {
  pname = "tmux-menu";
  version = "0.1.25";

  src = pkgs.fetchCrate {
    inherit pname version;
    hash = "sha256-3jhL1v975di+I99hXFATsKWU0rg5x2YDvHTRdP7zxW4=";
  };

  cargoHash = "sha256-b6Fdlddqiiwd+yB9HHOPYQk83xSqLLYmdnomwgRLJ28=";
  cargoDepsName = pname;
}
