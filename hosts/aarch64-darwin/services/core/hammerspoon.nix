{
  services.hammerspoon = {
    enable = true;
    keybindings = {
      "rcmd-w".lua = "hs.spaces.toggleMissionControl()";
      "rcmd-k".sendKey.key = "left";
      "rcmd-l".sendKey.key = "down";
      "rcmd-o".sendKey.key = "up";
      "rcmd-0x29".sendKey.key = "right";
    };
  };
}
