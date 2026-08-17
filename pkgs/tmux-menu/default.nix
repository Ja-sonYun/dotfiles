{ pkgs, ... }:

pkgs.rustPlatform.buildRustPackage rec {
  pname = "tmux-menu";
  version = "0.1.26";

  src = pkgs.fetchFromGitHub {
    owner = "Ja-sonYun";
    repo = "tmux-easy-menu";
    rev = "89f3008a92199997a09113ddb14fbba962e72854";
    hash = "sha256-08HwEvi3isuGVqqozahzlODxRM3+NnvBAvbIZpBumIs=";
  };

  cargoHash = "sha256-NwZUaXiJkq6wr9dF8cgSIzzeLASscAh6FH6fSaOu4ZM=";
  cargoDepsName = pname;
}
