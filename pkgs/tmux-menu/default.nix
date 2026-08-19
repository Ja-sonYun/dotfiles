{ pkgs, ... }:

pkgs.rustPlatform.buildRustPackage rec {
  pname = "tmux-menu";
  version = "0.1.27";

  src = pkgs.fetchFromGitHub {
    owner = "Ja-sonYun";
    repo = "tmux-easy-menu";
    rev = "5bb684a1baccf52fc264bb51ef1c5e075499804d";
    hash = "sha256-1LMZV4W76VZraymFzhwdn8tgfORbxHyz1Mv7cPbLwYM=";
  };

  cargoHash = "sha256-YBKusEc2cRu8zV/LHUENHq2E+zA7TCBc0eDLaaMIbq8=";
  cargoDepsName = pname;
}
