{ pkgs, ... }:

pkgs.rustPlatform.buildRustPackage rec {
  pname = "tmux-menu";
  version = "0.1.22";

  src = pkgs.fetchCrate {
    inherit pname version;
    hash = "sha256-AcH6R+PT/WDF3TbVGd7xwmUhn9G8NseSHlyAwvJUXWU=";
  };

  cargoHash = "sha256-WUH5IiB1yIDWYGXRNtYWxWGFrTL18d1a879TNiXdAnY=";
  cargoDepsName = pname;
}
