{ pkgs, ... }:

pkgs.rustPlatform.buildRustPackage rec {
  pname = "tmux-menu";
  version = "0.1.33";

  src = pkgs.fetchFromGitHub {
    owner = "Ja-sonYun";
    repo = "tmux-easy-menu";
    rev = "689b11403b34abdca2513cd0ecdab4b5d0304d17";
    hash = "sha256-P2LqOGoJQ/J5EMqAyXH4Bi03SMo9IeQxIpB4zTAYtb4=";
  };

  cargoHash = "sha256-Sh/+U3F5rz/BxNtq4fMX5fYr0fSjDVpSYm4j6L+nY/Y=";
  cargoDepsName = pname;
}
