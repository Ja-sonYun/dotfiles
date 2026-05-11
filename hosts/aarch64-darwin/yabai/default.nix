{ pkgs, lib, ... }:

let
  notchDisplayUuid = "37D8832A-2D66-02CA-B9F7-8F30A301B230";
  normalBar = 9;
  notchBar = 0;

  yabaiSettings = {
    layout = "bsp";

    top_padding = 7;
    bottom_padding = 8;
    left_padding = 4;
    right_padding = 4;
    window_gap = 4;

    mouse_follows_focus = "off";
    focus_follows_mouse = "off";

    window_opacity = "off";
    window_shadow = "float";

    window_border = "on";
    window_border_width = 2;

    active_window_border_color = "0xfff00031";
    normal_window_border_color = "0x00FFFFFF";
    insert_feedback_color = "0xE02d74da";

    active_window_opacity = "0.0";
    normal_window_opacity = "0.0";
    window_border_blur = "off";
    split_ratio = "0.50";

    auto_balance = "off";

    mouse_modifier = "fn";
    mouse_action1 = "move";
    mouse_action2 = "resize";
  };

  rules = [
    {
      label = "default-unmanaged";
      app = ".*";
      manage = "off";
      "sub-layer" = "above";
    }
    {
      label = "Ghostty";
      app = "^Ghostty$";
      manage = "on";
      "sub-layer" = "normal";
    }
    {
      label = "Chrome";
      app = "^(Google Chrome|Chrome)$";
      manage = "on";
      "sub-layer" = "normal";
    }
    {
      label = "Slack";
      app = "^Slack$";
      manage = "on";
      "sub-layer" = "normal";
    }
    {
      label = "Safari";
      app = "^Safari$";
      manage = "on";
      "sub-layer" = "normal";
    }
    {
      label = "Obsidian";
      app = "^Obsidian$";
      manage = "on";
      "sub-layer" = "normal";
    }
    {
      label = "VS Code";
      app = "^(Code|Visual Studio Code)$";
      manage = "on";
      "sub-layer" = "normal";
    }
    {
      label = "DEVONthink";
      app = "^(DEVONthink|DEVONthink 3)$";
      manage = "on";
      "sub-layer" = "normal";
    }
    {
      label = "Safari Settings";
      app = "^Safari$";
      title = "^(General|(Tab|Password|Website|Extension)s|AutoFill|Se(arch|curity)|Privacy|Advance)$";
      manage = "off";
      "sub-layer" = "above";
    }
  ];

  renderAttrs =
    keys: attrs:
    lib.concatStringsSep " " (
      map
        (key: lib.escapeShellArg "${key}=${toString attrs.${key}}")
        (lib.filter (key: builtins.hasAttr key attrs) keys)
    );

  renderRule =
    rule:
    "yabai -m rule --add ${renderAttrs [ "label" "app" "title" "role" "subrole" "manage" "sub-layer" "sticky" "grid" ] rule}";

  renderSignal =
    signal:
    "yabai -m signal --add ${renderAttrs [ "event" "action" ] signal}";

  notchExternalBar = pkgs.writeShellApplication {
    name = "yabai-apply-external-bar";
    runtimeInputs = [
      pkgs.jq
      pkgs.yabai
    ];
    text = ''
      if yabai -m query --displays | jq -e --arg uuid ${lib.escapeShellArg notchDisplayUuid} 'any(.[]; .uuid == $uuid)' >/dev/null; then
        yabai -m config external_bar ${lib.escapeShellArg "main:${toString notchBar}:0"}
      else
        yabai -m config external_bar ${lib.escapeShellArg "main:${toString normalBar}:0"}
      fi
    '';
  };

  sketchybar = "${pkgs.sketchybar}/bin/sketchybar";

  signals = [
    {
      event = "dock_did_restart";
      action = "/usr/bin/sudo ${pkgs.yabai}/bin/yabai --load-sa";
    }
    {
      event = "window_focused";
      action = "${sketchybar} --trigger window_focus";
    }
    {
      event = "window_created";
      action = "${sketchybar} --trigger windows_on_spaces";
    }
    {
      event = "window_destroyed";
      action = "${sketchybar} --trigger windows_on_spaces";
    }
    {
      event = "window_moved";
      action = "${sketchybar} --trigger windows_on_spaces";
    }
    {
      event = "space_changed";
      action = "${sketchybar} --trigger windows_on_spaces";
    }
    {
      event = "display_added";
      action = "${notchExternalBar}/bin/yabai-apply-external-bar";
    }
    {
      event = "display_removed";
      action = "${notchExternalBar}/bin/yabai-apply-external-bar";
    }
  ];

  yabaiExtraConfig = ''
    ${lib.concatMapStringsSep "\n" renderRule rules}
    yabai -m rule --apply

    ${lib.concatMapStringsSep "\n" renderSignal signals}

    ${notchExternalBar}/bin/yabai-apply-external-bar
  '';
in
{
  services.yabai = {
    enable = true;
    enableScriptingAddition = true;
    config = yabaiSettings;
    extraConfig = yabaiExtraConfig;
  };

  launchd.user.agents.yabai.serviceConfig = {
    StandardOutPath = "/tmp/yabai.out.log";
    StandardErrorPath = "/tmp/yabai.err.log";
  };
}
