{
  config,
  lib,
  pkgs,
  userhome,
  ...
}:
let
  cfg = config.services.yabai;
  hasSignedYabai = config.services.codeSigning.targets ? yabai;
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
  renderAttrs =
    keys: attrs:
    lib.concatStringsSep " " (
      map (key: lib.escapeShellArg "${key}=${toString attrs.${key}}") (
        lib.filter (key: builtins.hasAttr key attrs) keys
      )
    );

  renderRule = rule: "yabai -m rule --add ${renderAttrs (builtins.attrNames rule) rule}";

  displayExtraConfig = import ./display-management.nix {
    inherit lib pkgs renderAttrs;
    yabaiSettings = cfg.config;
    inherit (cfg.displayManagement) targetDesktopsPerDisplay;
  };
in
{
  imports = [
    ./stackline
    ./extensions/desktop-indicator
  ];

  options.services.yabai = {
    rules = lib.mkOption {
      type = lib.types.listOf (lib.types.attrsOf lib.types.str);
      default = [ ];
      description = "Window rules applied when yabai starts.";
    };
    scriptingAddition.enable = lib.mkEnableOption "the locally managed yabai scripting addition";
    displayManagement = {
      enable = lib.mkEnableOption "yabai desktop reconciliation on display changes";
      targetDesktopsPerDisplay = lib.mkOption {
        type = lib.types.ints.positive;
        default = 4;
        description = "Number of regular desktops to maintain on each display.";
      };
    };
  };

  config = lib.mkMerge [
    (lib.mkIf config.services.yabai.enable {
      services.codeSigning.targets.yabai = {
        source = "${pkgs.yabai}/bin/yabai";
        target = signedYabaiPath;
        restartLaunchAgent = "org.nixos.yabai";
      };

      services.yabai = {
        package = if hasSignedYabai then signedYabaiPackage else pkgs.yabai;
        enableScriptingAddition = lib.mkIf cfg.scriptingAddition.enable false;
        extraConfig = lib.mkBefore ''
          ${lib.optionalString cfg.scriptingAddition.enable "/usr/bin/sudo ${pkgs.yabai}/bin/yabai --load-sa"}

          ${lib.optionalString (cfg.rules != [ ]) ''
            ${lib.concatMapStringsSep "\n" renderRule cfg.rules}
            yabai -m rule --apply
          ''}

          ${lib.optionalString cfg.scriptingAddition.enable ''
            yabai -m signal --remove load-sa-after-dock-restart 2>/dev/null || true
            yabai -m signal --add label=load-sa-after-dock-restart event=dock_did_restart action=${lib.escapeShellArg "/usr/bin/sudo ${pkgs.yabai}/bin/yabai --load-sa"}
          ''}
          ${lib.optionalString cfg.displayManagement.enable displayExtraConfig}
        '';
      };
      environment.etc."sudoers.d/yabai" = lib.mkIf cfg.scriptingAddition.enable {
        source = lib.mkForce yabaiSaSudoers;
      };
      launchd.user.agents.yabai = {
        startupGuard = {
          enable = true;
          extraExecutables = lib.optional hasSignedYabai signedYabaiPath;
          readableFileFlags = [ "-c" ];
        };
        serviceConfig = {
          StandardOutPath = "/tmp/yabai.out.log";
          StandardErrorPath = "/tmp/yabai.err.log";
        };
      };
    })
  ];
}
