{
  config,
  lib,
  pkgs,
  ...
}:
let
  signedYabaiDir = "${config.home.homeDirectory}/.local/libexec/yabai";
  signedYabaiPath = "${signedYabaiDir}/yabai";
in
{
  home.activation.installSignedYabai = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    source_path=${lib.escapeShellArg "${pkgs.yabai}/bin/yabai"}
    target_dir=${lib.escapeShellArg signedYabaiDir}
    target_path=${lib.escapeShellArg signedYabaiPath}
    marker_path="$target_path.source"
    current_source=$(/usr/bin/readlink "$marker_path" 2>/dev/null || true)

    if [[ ! -x "$target_path" || "$current_source" != "$source_path" ]]; then
      run /bin/mkdir -p "$target_dir"
      run /usr/bin/install -m 0755 "$source_path" "$target_path.new"
      if ! run /usr/bin/codesign --force --sign yabai-cert "$target_path.new"; then
        run /bin/rm -f "$target_path.new"
        exit 1
      fi
      run /bin/mv -f "$target_path.new" "$target_path"
      run /bin/ln -sfn "$source_path" "$marker_path"

      uid=$(/usr/bin/id -u)
      if /bin/launchctl print "gui/$uid/org.nixos.yabai" >/dev/null 2>&1; then
        run /bin/launchctl kickstart -k "gui/$uid/org.nixos.yabai"
      fi
    fi
  '';
}
