{ pkgs, infraSrc, ... }:
pkgs.writeShellApplication {
  name = "cf-tunnel";
  runtimeInputs = [
    pkgs.age
    pkgs.cloudflared
  ];
  text = builtins.readFile (infraSrc + "/cloudflare/generated/tunnel");
}
