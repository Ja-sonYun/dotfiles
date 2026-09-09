{
  lib,
  pkgs,
  renderAttrs,
  yabaiSettings,
}:

let
  targetDesktopsPerDisplay = 4;

  renderSignal = signal: ''
    yabai -m signal --remove ${lib.escapeShellArg signal.label} 2>/dev/null || true
    yabai -m signal --add ${renderAttrs [ "label" "event" "action" ] signal}
  '';

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
      label = "load-sa-after-dock-restart";
      event = "dock_did_restart";
      action = "/usr/bin/sudo ${pkgs.yabai}/bin/yabai --load-sa";
    }
    {
      label = "reconcile-spaces-after-display-added";
      event = "display_added";
      action = "${reconcileSpaces}/bin/yabai-reconcile-spaces";
    }
    {
      label = "reconcile-spaces-after-display-removed";
      event = "display_removed";
      action = "${reconcileSpaces}/bin/yabai-reconcile-spaces";
    }
    {
      label = "reconcile-spaces-after-display-moved";
      event = "display_moved";
      action = "${reconcileSpaces}/bin/yabai-reconcile-spaces";
    }
    {
      label = "reconcile-spaces-after-display-resized";
      event = "display_resized";
      action = "${reconcileSpaces}/bin/yabai-reconcile-spaces";
    }
    {
      label = "reconcile-spaces-after-system-wake";
      event = "system_woke";
      action = "${reconcileSpaces}/bin/yabai-reconcile-spaces";
    }
  ];
in
''
  ${lib.concatMapStringsSep "\n" renderSignal signals}

  yabai -m config external_bar all:0:0
  ${reconcileSpaces}/bin/yabai-reconcile-spaces
''
