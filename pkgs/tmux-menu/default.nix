{ pkgs, ... }:

pkgs.rustPlatform.buildRustPackage rec {
  pname = "tmux-menu";
  version = "0.1.20";

  src = pkgs.fetchCrate {
    inherit pname version;
    hash = "sha256-CIVb1Eqc5jYQdDGfljzUL9ek651O8dlwnZIonp+eSsA=";
  };

  cargoHash = "sha256-99PZqaE0g32YCZxknGB7XdQYDGaleCOWsHZ2I1LJBZg=";
  cargoDepsName = pname;
}
