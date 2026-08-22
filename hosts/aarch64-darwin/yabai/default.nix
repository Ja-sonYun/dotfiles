{
  pkgs,
  lib,
  ...
}:

let
  yabaiSettings = {
    layout = "bsp";

    top_padding = 4;
    bottom_padding = 8;
    left_padding = 4;
    right_padding = 4;
    window_gap = 4;

    mouse_follows_focus = "off";
    focus_follows_mouse = "off";

    window_opacity = "off";
    window_shadow = "float";

    window_border = "off";
    insert_feedback_color = "0xE02d74da";

    active_window_opacity = "0.0";
    normal_window_opacity = "0.0";
    split_ratio = "0.50";

    auto_balance = "off";

    mouse_modifier = "fn";
    mouse_action1 = "move";
    mouse_action2 = "resize";
  };

  rules = import ./rules.nix;

  renderAttrs =
    keys: attrs:
    lib.concatStringsSep " " (
      map (key: lib.escapeShellArg "${key}=${toString attrs.${key}}") (
        lib.filter (key: builtins.hasAttr key attrs) keys
      )
    );

  renderRule =
    rule:
    "yabai -m rule --add ${
      renderAttrs [
        "label"
        "app"
        "title"
        "role"
        "subrole"
        "manage"
        "sub-layer"
        "sticky"
        "grid"
      ] rule
    }";

  displayExtraConfig = import ./display-management.nix {
    inherit
      lib
      pkgs
      renderAttrs
      yabaiSettings
      ;
  };

  yabaiExtraConfig = ''
    /usr/bin/sudo ${pkgs.yabai}/bin/yabai --load-sa

    ${lib.concatMapStringsSep "\n" renderRule rules}
    yabai -m rule --apply

    ${displayExtraConfig}
  '';
in
{
  services.yabai = {
    enable = true;
    enableScriptingAddition = false;
    config = yabaiSettings;
    extraConfig = yabaiExtraConfig;
  };

  launchd.user.agents.yabai.serviceConfig = {
    StandardOutPath = "/tmp/yabai.out.log";
    StandardErrorPath = "/tmp/yabai.err.log";
  };
}
