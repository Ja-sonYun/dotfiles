{ config, lib, ... }:
let
  enabled =
    config.services.yabai.stackline.enable || config.services.yabai.extensions.desktopIndicator.enable;
  events = [
    "space_changed"
    "space_created"
    "space_destroyed"
    "display_changed"
    "display_added"
    "display_removed"
    "window_created"
    "window_destroyed"
    "window_focused"
    "window_moved"
    "window_resized"
    "window_minimized"
    "window_deminimized"
    "application_visible"
    "application_hidden"
    "mission_control_exit"
    "system_woke"
  ];
in
{
  config = lib.mkIf config.services.yabai.enable {
    services.yabai.extraConfig = lib.concatMapStringsSep "\n" (
      event:
      let
        forward =
          enabled
          && !(lib.elem event [
            "window_focused"
            "window_moved"
            "window_resized"
          ]);
        action =
          (lib.escapeShellArgs [
            "/Applications/Hammerspoon.app/Contents/Frameworks/hs/hs"
            "-q"
            "-t"
            "1"
            "-c"
            "require('yabai-events').emit('${event}')"
          ])
          + " </dev/null";
      in
      ''
        yabai -m signal --remove hammerspoon-${event} 2>/dev/null || true
        ${lib.optionalString forward "yabai -m signal --add label=hammerspoon-${event} event=${event} action=${lib.escapeShellArg action}"}
      ''
    ) events;

    services.hammerspoon.scripts = lib.mkIf enabled [
      {
        name = "yabai-events.lua";
        path = ./events.lua;
      }
    ];
  };
}
