{ pkgs, ... }:
pkgs.writeShellApplication {
  name = "cf-tunnel";
  runtimeInputs = [
    pkgs.age
    pkgs.cloudflared
  ];
  text = builtins.readFile ../../infra/cloudflare/generated/tunnel;
}
