{
  lib,
  pkgs,
  renderAttrs,
  yabaiSettings,
}:

let
  notchDisplayUuid = "37D8832A-2D66-02CA-B9F7-8F30A301B230";
  normalBar = 0;
  notchBar = 0;
  targetDesktopsPerDisplay = 4;

  renderSignal = signal: "yabai -m signal --add ${renderAttrs [ "event" "action" ] signal}";

  notchExternalBar = pkgs.writeShellApplication {
    name = "yabai-apply-external-bar";
    runtimeInputs = [
      pkgs.jq
      pkgs.yabai
    ];
    text = ''
      if yabai -m query --displays | jq -e --arg uuid ${lib.escapeShellArg notchDisplayUuid} 'any(.[]; .uuid == $uuid)' >/dev/null; then
        yabai -m config external_bar ${lib.escapeShellArg "all:${toString notchBar}:0"}
      else
        yabai -m config external_bar ${lib.escapeShellArg "all:${toString normalBar}:0"}
      fi
    '';
  };

  reconcileSpaces = pkgs.writeShellApplication {
    name = "yabai-reconcile-spaces";
    runtimeInputs = [
      pkgs.jq
      pkgs.yabai
    ];
    text = ''
      target_desktops=${toString targetDesktopsPerDisplay}
      padding_spec=${lib.escapeShellArg "abs:${toString yabaiSettings.top_padding}:${toString yabaiSettings.bottom_padding}:${toString yabaiSettings.left_padding}:${toString yabaiSettings.right_padding}"}
      gap_spec=${lib.escapeShellArg "abs:${toString yabaiSettings.window_gap}"}

      ${builtins.readFile ./reconcile-spaces.sh}
    '';
  };

  signals = [
    {
      event = "dock_did_restart";
      action = "/usr/bin/sudo ${pkgs.yabai}/bin/yabai --load-sa";
    }
    {
      event = "display_added";
      action = "${notchExternalBar}/bin/yabai-apply-external-bar";
    }
    {
      event = "display_added";
      action = "${reconcileSpaces}/bin/yabai-reconcile-spaces";
    }
    {
      event = "display_removed";
      action = "${notchExternalBar}/bin/yabai-apply-external-bar";
    }
    {
      event = "display_removed";
      action = "${reconcileSpaces}/bin/yabai-reconcile-spaces";
    }
    {
      event = "display_moved";
      action = "${reconcileSpaces}/bin/yabai-reconcile-spaces";
    }
    {
      event = "display_resized";
      action = "${reconcileSpaces}/bin/yabai-reconcile-spaces";
    }
    {
      event = "system_woke";
      action = "${reconcileSpaces}/bin/yabai-reconcile-spaces";
    }
  ];
in
''
  ${lib.concatMapStringsSep "\n" renderSignal signals}

  ${notchExternalBar}/bin/yabai-apply-external-bar
  ${reconcileSpaces}/bin/yabai-reconcile-spaces
''
