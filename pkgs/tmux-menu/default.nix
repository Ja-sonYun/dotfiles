{ pkgs, ... }:

pkgs.rustPlatform.buildRustPackage rec {
  pname = "tmux-menu";
  version = "0.1.21";

  src = pkgs.fetchCrate {
    inherit pname version;
    hash = "sha256-dRnxoGGM7OfYn/sQlmZT5EFdPVYGVF31OJ+/Rrk5sEA=";
  };

  cargoHash = "sha256-pSq2ZzoziuGdh5gn0XPH2kE0pv2cPLs0l/ddPyIphN0=";
  cargoDepsName = pname;
}
