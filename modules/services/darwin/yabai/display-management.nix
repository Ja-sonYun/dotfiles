{
  lib,
  pkgs,
  renderAttrs,
  yabaiSettings,
  targetDesktopsPerDisplay,
  logging,
  yabaiPackage,
}:

let
  renderSignal = signal: ''
    yabai -m signal --remove ${lib.escapeShellArg signal.label} 2>/dev/null || true
    yabai -m signal --add ${renderAttrs [ "label" "event" "action" ] signal}
  '';

  reconcileSpacesWorker = pkgs.writeShellApplication {
    name = "yabai-reconcile-spaces-worker";
    runtimeInputs = [
      pkgs.jq
      yabaiPackage
    ];
    text = ''
      ${lib.optionalString logging.enable ''
        enable -f ${lib.escapeShellArg logging.bashLibrary} dotfiles_log 2>/dev/null || :
      ''}
      log_event() {
        ${
          if logging.enable then
            ''
              builtin dotfiles_log ${lib.escapeShellArg logging.socketPath} yabai.reconcile "$@" >/dev/null 2>&1 || :
            ''
          else
            ":"
        }
      }
      yabai() {
        local status arguments
        if command yabai "$@"; then
          return 0
        else
          status=$?
        fi
        printf -v arguments '%q ' "$@"
        log_event error command_failed "command=$arguments" "exit_code=$status"
        return "$status"
      }
      target_desktops=${toString targetDesktopsPerDisplay}
      padding_spec=${lib.escapeShellArg "abs:${toString (yabaiSettings.top_padding or 0)}:${toString (yabaiSettings.bottom_padding or 0)}:${toString (yabaiSettings.left_padding or 0)}:${toString (yabaiSettings.right_padding or 0)}"}
      gap_spec=${lib.escapeShellArg "abs:${toString (yabaiSettings.window_gap or 0)}"}

      ${builtins.readFile ./reconcile-spaces.sh}
    '';
  };

  reconcileSpaces = pkgs.writeShellApplication {
    name = "yabai-reconcile-spaces";
    text = ''
      lock_file="''${TMPDIR:-/tmp}/yabai-reconcile-spaces-$UID.lock"
      printf '%s\n' "$$" >"$lock_file.request.$$"
      /bin/mv -f "$lock_file.request.$$" "$lock_file.request"

      /bin/sleep 2
      exec /usr/bin/lockf -k "$lock_file" ${reconcileSpacesWorker}/bin/yabai-reconcile-spaces-worker "$lock_file" "$$"
    '';
  };

  signals = [
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
