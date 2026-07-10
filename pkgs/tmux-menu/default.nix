{ pkgs, ... }:

pkgs.rustPlatform.buildRustPackage rec {
  pname = "tmux-menu";
  version = "0.1.24";

  src = pkgs.fetchCrate {
    inherit pname version;
    hash = "sha256-TqEyvkevnufd8sO5dWuEnHCc1lTr7WeaYkjS1wAMvKc=";
  };

  cargoHash = "sha256-9zVSumDXWGPS26pySR+KdeD/KAP+frUYr73kR8iALpM=";
  cargoDepsName = pname;
}
