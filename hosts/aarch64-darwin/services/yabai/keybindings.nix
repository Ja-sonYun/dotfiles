{
  config,
  ...
}:

let
  controller = config.services.yabai.extensions.controller;
  send = payload: {
    socket = {
      path = controller.socketPath;
      inherit payload;
    };
  };
  command =
    args:
    send {
      action = "command";
      inherit args;
    };
  space =
    action: number:
    send {
      inherit action;
      space = number;
    };
in
{
  services.hammerspoon.keybindings = {
    "lalt-h" = command [
      "window"
      "--focus"
      "west"
    ];
    "lalt-j" = command [
      "window"
      "--focus"
      "south"
    ];
    "lalt-k" = command [
      "window"
      "--focus"
      "north"
    ];
    "lalt-l" = command [
      "window"
      "--focus"
      "east"
    ];

    "shift-lalt-h" = command [
      "window"
      "--swap"
      "west"
    ];
    "shift-lalt-j" = command [
      "window"
      "--swap"
      "south"
    ];
    "shift-lalt-k" = command [
      "window"
      "--swap"
      "north"
    ];
    "shift-lalt-l" = command [
      "window"
      "--swap"
      "east"
    ];
    "shift-lalt-s" = send { action = "stack-recent"; };

    "lalt-p" = send { action = "focus-stack-prev"; };
    "lalt-n" = send { action = "focus-stack-next"; };

    "shift-lalt-1" = space "move-space" 1;
    "shift-lalt-2" = space "move-space" 2;
    "shift-lalt-3" = space "move-space" 3;
    "shift-lalt-4" = space "move-space" 4;

    "rcmd-a" = command [
      "display"
      "--space"
      "prev"
    ];
    "rcmd-d" = command [
      "display"
      "--space"
      "next"
    ];

    "rcmd-1" = space "focus-space" 1;
    "rcmd-2" = space "focus-space" 2;
    "rcmd-3" = space "focus-space" 3;
    "rcmd-4" = space "focus-space" 4;

    "shift-rcmd-n" = command [
      "space"
      "--create"
    ];
    "shift-rcmd-d" = command [
      "space"
      "--destroy"
    ];

    "ctrl-lalt-h" = command [
      "window"
      "--resize"
      "left:-50:0"
      "--resize"
      "right:-50:0"
    ];
    "ctrl-lalt-j" = command [
      "window"
      "--resize"
      "bottom:0:50"
      "--resize"
      "top:0:50"
    ];
    "ctrl-lalt-k" = command [
      "window"
      "--resize"
      "top:0:-50"
      "--resize"
      "bottom:0:-50"
    ];
    "ctrl-lalt-l" = command [
      "window"
      "--resize"
      "right:50:0"
      "--resize"
      "left:50:0"
    ];

    "ctrl-lalt-1" = command [
      "window"
      "--display"
      "1"
      "--focus"
    ];
    "ctrl-lalt-2" = command [
      "window"
      "--display"
      "2"
      "--focus"
    ];
    "ctrl-lalt-3" = command [
      "window"
      "--display"
      "3"
      "--focus"
    ];
    "ctrl-lalt-4" = command [
      "window"
      "--display"
      "4"
      "--focus"
    ];

    "ctrl-rcmd-e" = command [
      "space"
      "--balance"
    ];
    "ctrl-rcmd-g" = command [
      "space"
      "--toggle"
      "padding"
      "--toggle"
      "gap"
    ];

    "shift-rcmd-x" = command [
      "space"
      "--mirror"
      "x-axis"
    ];
    "shift-rcmd-y" = command [
      "space"
      "--mirror"
      "y-axis"
    ];

    "shift-ctrl-lalt-h" = command [
      "window"
      "--insert"
      "west"
    ];
    "shift-ctrl-lalt-j" = command [
      "window"
      "--insert"
      "south"
    ];
    "shift-ctrl-lalt-k" = command [
      "window"
      "--insert"
      "north"
    ];
    "shift-ctrl-lalt-l" = command [
      "window"
      "--insert"
      "east"
    ];
    "shift-ctrl-lalt-s" = command [
      "window"
      "--insert"
      "stack"
    ];

    "rcmd-f" = send { action = "toggle-float"; };

    "shift-ctrl-rcmd-r".command =
      "/usr/bin/osascript -e 'display notification \"Restarting yabai\" with title \"yabai\"'; /bin/launchctl kickstart -k \"gui/\${UID}/org.nixos.yabai\"";

    "ctrl-cmd-f" = command [
      "window"
      "--toggle"
      "zoom-fullscreen"
    ];
    "shift-rcmd-f" = command [
      "window"
      "--toggle"
      "native-fullscreen"
    ];
  };
}
