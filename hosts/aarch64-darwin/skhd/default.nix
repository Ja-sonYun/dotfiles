{ pkgs, ... }:

let
  yabai = "${pkgs.yabai}/bin/yabai";
  jq = "${pkgs.jq}/bin/jq";
  macism = "${pkgs.macism}/bin/macism";
  skhd = "${pkgs.skhd}/bin/skhd";
  rotateInputSource = pkgs.writeShellApplication {
    name = "rotate-input-source";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.macism
    ];
    text = builtins.readFile ./rotate-input-source.sh;
  };
  focusedDisplaySpace =
    number:
    ''focused_display="$(${yabai} -m query --spaces --space | ${jq} -er '.display')" && target_space="$(${yabai} -m query --spaces --display "$focused_display" | ${jq} -er 'map(select(."is-native-fullscreen" == false))[${toString (number - 1)}].index')" &&'';
  displaySpace =
    number:
    ''target_space="$(${yabai} -m query --spaces --display ${toString number} | ${jq} -er 'map(select(."is-native-fullscreen" == false)) | (map(select(."is-visible" == true))[0] // .[0]) | .index')" &&'';
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

      "shift + lalt - 1" =
        "${focusedDisplaySpace 1} ${yabai} -m window --space \"$target_space\" --focus";
      "shift + lalt - 2" =
        "${focusedDisplaySpace 2} ${yabai} -m window --space \"$target_space\" --focus";
      "shift + lalt - 3" =
        "${focusedDisplaySpace 3} ${yabai} -m window --space \"$target_space\" --focus";
      "shift + lalt - 4" =
        "${focusedDisplaySpace 4} ${yabai} -m window --space \"$target_space\" --focus";

      "rcmd - a" =
        "${yabai} -m query --spaces --display | ${jq} -e '.[0].\"has-focus\" == false' >/dev/null && ${yabai} -m space --focus prev";
      "rcmd - d" =
        "${yabai} -m query --spaces --display | ${jq} -e '.[-1].\"has-focus\" == false' >/dev/null && ${yabai} -m space --focus next";

      "rcmd - 1" = "${focusedDisplaySpace 1} ${yabai} -m space --focus \"$target_space\"";
      "rcmd - 2" = "${focusedDisplaySpace 2} ${yabai} -m space --focus \"$target_space\"";
      "rcmd - 3" = "${focusedDisplaySpace 3} ${yabai} -m space --focus \"$target_space\"";
      "rcmd - 4" = "${focusedDisplaySpace 4} ${yabai} -m space --focus \"$target_space\"";

      "shift + rcmd - n" = "${yabai} -m space --create";
      "shift + rcmd - d" = "${yabai} -m space --destroy";

      "ctrl + lalt - h" = "${yabai} -m window --resize left:-50:0 --resize right:-50:0";
      "ctrl + lalt - j" = "${yabai} -m window --resize bottom:0:50 --resize top:0:50";
      "ctrl + lalt - k" = "${yabai} -m window --resize top:0:-50 --resize bottom:0:-50";
      "ctrl + lalt - l" = "${yabai} -m window --resize right:50:0 --resize left:50:0";

      "ctrl + lalt - 1" = "${displaySpace 1} ${yabai} -m window --space \"$target_space\" --focus";
      "ctrl + lalt - 2" = "${displaySpace 2} ${yabai} -m window --space \"$target_space\" --focus";
      "ctrl + lalt - 3" = "${displaySpace 3} ${yabai} -m window --space \"$target_space\" --focus";
      "ctrl + lalt - 4" = "${displaySpace 4} ${yabai} -m window --space \"$target_space\" --focus";

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
      "ctrl - space" = "${rotateInputSource}/bin/rotate-input-source";

      "rcmd - w" = "${skhd} -k \"ctrl - up\"";

      "rcmd - k" = "${skhd} -k \"left\"";
      "rcmd - l" = "${skhd} -k \"down\"";
      "rcmd - o" = "${skhd} -k \"up\"";
      "rcmd - 0x29" = "${skhd} -k \"right\"";
    };
  };
}
