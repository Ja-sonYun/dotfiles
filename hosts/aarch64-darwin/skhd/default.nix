{ pkgs, ... }:

let
  yabai = "${pkgs.yabai}/bin/yabai";
  jq = "${pkgs.jq}/bin/jq";
  macism = "${pkgs.macism}/bin/macism";
  skhd = "${pkgs.skhd}/bin/skhd";
in
{
  services.skhd = {
    enable = true;
    bindings = {
      "lalt - h" = "${yabai} -m window --focus west";
      "lalt - j" = "${yabai} -m window --focus south";
      "lalt - k" = "${yabai} -m window --focus north";
      "lalt - l" = "${yabai} -m window --focus east";

      "shift + lalt - h" = "${yabai} -m window --warp west";
      "shift + lalt - j" = "${yabai} -m window --warp south";
      "shift + lalt - k" = "${yabai} -m window --warp north";
      "shift + lalt - l" = "${yabai} -m window --warp east";
      "shift + lalt - s" = "${yabai} -m window --stack recent";

      "lalt - p" = "${yabai} -m window --focus stack.prev || ${yabai} -m window --focus stack.last";
      "lalt - n" = "${yabai} -m window --focus stack.next || ${yabai} -m window --focus stack.first";

      "shift + lalt - 1" = "${yabai} -m window --space 1 --focus";
      "shift + lalt - 2" = "${yabai} -m window --space 2 --focus";
      "shift + lalt - 3" = "${yabai} -m window --space 3 --focus";
      "shift + lalt - 4" = "${yabai} -m window --space 4 --focus";
      "shift + lalt - 5" = "${yabai} -m window --space 5 --focus";

      "rcmd - a" =
        "${yabai} -m query --spaces --display | ${jq} -e '.[0].\"has-focus\" == false' >/dev/null && ${yabai} -m space --focus prev";
      "rcmd - d" =
        "${yabai} -m query --spaces --display | ${jq} -e '.[-1].\"has-focus\" == false' >/dev/null && ${yabai} -m space --focus next";

      "rcmd - 1" = "${yabai} -m space --focus 1";
      "rcmd - 2" = "${yabai} -m space --focus 2";
      "rcmd - 3" = "${yabai} -m space --focus 3";
      "rcmd - 4" = "${yabai} -m space --focus 4";
      "rcmd - 5" = "${yabai} -m space --focus 5";
      "rcmd - 6" = "${yabai} -m space --focus 6";
      "rcmd - 7" = "${yabai} -m space --focus 7";

      "shift + rcmd - n" = "${yabai} -m space --create";
      "shift + rcmd - d" = "${yabai} -m space --destroy";

      "ctrl + lalt - h" = "${yabai} -m window --resize left:-50:0 --resize right:-50:0";
      "ctrl + lalt - j" = "${yabai} -m window --resize bottom:0:50 --resize top:0:50";
      "ctrl + lalt - k" = "${yabai} -m window --resize top:0:-50 --resize bottom:0:-50";
      "ctrl + lalt - l" = "${yabai} -m window --resize right:50:0 --resize left:50:0";

      "ctrl + rcmd - e" = "${yabai} -m space --balance";
      "ctrl + rcmd - g" = "${yabai} -m space --toggle padding --toggle gap";

      "shift + rcmd - x" = "${yabai} -m space --mirror x-axis";
      "shift + rcmd - y" = "${yabai} -m space --mirror y-axis";

      "shift + ctrl + lalt - h" = "${yabai} -m window --insert west";
      "shift + ctrl + lalt - j" = "${yabai} -m window --insert south";
      "shift + ctrl + lalt - k" = "${yabai} -m window --insert north";
      "shift + ctrl + lalt - l" = "${yabai} -m window --insert east";
      "shift + ctrl + lalt - s" = "${yabai} -m window --insert stack";

      "rcmd - f" = "${yabai} -m window --toggle float";

      "shift + ctrl + rcmd - r" =
        "/usr/bin/osascript -e 'display notification \"Restarting yabai\" with title \"yabai\"'; /bin/launchctl kickstart -k \"gui/\${UID}/org.nixos.yabai\"";

      "ctrl + cmd - f" = "${yabai} -m window --toggle zoom-fullscreen";
      "shift + rcmd - f" = "${yabai} -m window --toggle native-fullscreen";

      "rcmd - q" = "${macism} \"com.apple.keylayout.ABC\"";
      "rcmd - e" = "${macism} \"com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese\"";
      "rcmd - r" = "${macism} \"com.apple.inputmethod.Korean.2SetKorean\"";

      "rcmd - w" = "${skhd} -k \"ctrl - up\"";

      "rcmd - k" = "${skhd} -k \"left\"";
      "rcmd - l" = "${skhd} -k \"down\"";
      "rcmd - o" = "${skhd} -k \"up\"";
      "rcmd - 0x29" = "${skhd} -k \"right\"";
    };
  };

  launchd.user.agents.skhd.serviceConfig = {
    StandardOutPath = "/tmp/skhd.out.log";
    StandardErrorPath = "/tmp/skhd.err.log";
  };
}
