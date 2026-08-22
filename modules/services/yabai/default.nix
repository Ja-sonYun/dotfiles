{
  config,
  lib,
  pkgs,
  userhome,
  ...
}:
let
  signedYabaiPath = "${userhome}/.local/libexec/yabai/yabai";
  signedYabaiPackage = pkgs.writeShellScriptBin "yabai" ''
    exec ${lib.escapeShellArg signedYabaiPath} "$@"
  '';
  yabaiSaSudoers = pkgs.runCommand "sudoers-yabai" { } ''
    yabai_bin=${lib.escapeShellArg "${pkgs.yabai}/bin/yabai"}
    shasum=$(sha256sum "$yabai_bin" | cut -d' ' -f1)
    cat <<EOF >"$out"
    %admin ALL=(root) NOPASSWD: sha256:$shasum $yabai_bin --load-sa
    EOF
  '';
in
{
  config = lib.mkMerge [
    (lib.mkIf config.services.yabai.enable {
      services.yabai.package = signedYabaiPackage;
      environment.etc."sudoers.d/yabai".source = lib.mkForce yabaiSaSudoers;
      launchd.user.agents.yabai.serviceConfig = {
        StandardOutPath = "/tmp/yabai.out.log";
        StandardErrorPath = "/tmp/yabai.err.log";
      };
    })
  ];
}
