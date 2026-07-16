{ pkgs, ... }:

pkgs.rustPlatform.buildRustPackage rec {
  pname = "tmux-menu";
  version = "0.1.25";

  src = pkgs.fetchFromGitHub {
    owner = "Ja-sonYun";
    repo = "tmux-easy-menu";
    rev = "13ffeeea7d5762c45386a476ec22d4d55b8e1b89";
    hash = "sha256-0au5DcSDJX9vm2euxIw58VJ/vS0kTsGjGSDR99CILBQ=";
  };

  cargoHash = "sha256-b6Fdlddqiiwd+yB9HHOPYQk83xSqLLYmdnomwgRLJ28=";
  cargoDepsName = pname;
}
