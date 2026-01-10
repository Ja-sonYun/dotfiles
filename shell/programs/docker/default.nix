{ lib, pkgs, ... }:
lib.mkIf pkgs.stdenv.isLinux {
  home.packages = with pkgs; [
    colima
    docker-client
    docker-compose
    docker-buildx
    docker-credential-helpers
  ];
}
