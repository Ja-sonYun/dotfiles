_:
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

in
{
  services.yabai = {
    enable = true;
    stackline.enable = true;
    extensions.desktopIndicator.enable = true;
    config = yabaiSettings;
    rules = import ./rules.nix;
    scriptingAddition.enable = true;
    displayManagement = {
      enable = true;
      targetDesktopsPerDisplay = 4;
    };
  };
}
