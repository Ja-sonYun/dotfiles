{ pkgs, ... }:
{
  services.hammerspoon = {
    enable = true;
    keybindings = {
      "cmd-space" = {
        command = "${pkgs.macism}/bin/macism com.apple.keylayout.ABC";
        passthrough = true;
      };

      "rcmd-w".lua = "hs.spaces.toggleMissionControl()";
      "rcmd-k".sendKey.key = "left";
      "rcmd-l".sendKey.key = "down";
      "rcmd-o".sendKey.key = "up";
      "rcmd-0x29".sendKey.key = "right";
    };
  };
}
