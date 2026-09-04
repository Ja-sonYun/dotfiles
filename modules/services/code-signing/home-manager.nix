{
  config,
  lib,
  ...
}:
let
  cfg = config.services.codeSigning;
  targetType = import ./target-type.nix { inherit lib; };
  hasTargets = cfg.targets != { };
  targetsHaveIdentities = lib.all (target: target.identity != null) (lib.attrValues cfg.targets);
  installTargets = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (
      name: target:
      let
        sourceFingerprint = builtins.hashString "sha256" target.source;
      in
      ''
        install_signed_target \
          ${lib.escapeShellArg name} \
          ${lib.escapeShellArg target.source} \
          ${lib.escapeShellArg target.target} \
          ${lib.escapeShellArg target.identity} \
          ${lib.escapeShellArg sourceFingerprint} \
          ${lib.escapeShellArg (
            if target.restartLaunchAgent == null then "" else target.restartLaunchAgent
          )}
      ''
    ) cfg.targets
  );
in
{
  options.services.codeSigning.targets = lib.mkOption {
    type = lib.types.attrsOf targetType;
    default = { };
    description = "Resolved targets installed by the code-signing activation.";
  };

  config = lib.mkIf hasTargets {
    assertions = [
      {
        assertion = targetsHaveIdentities;
        message = "Every Home Manager code-signing target requires an identity.";
      }
    ];

    home.activation.installSignedTargets = lib.mkIf targetsHaveIdentities (
      lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        install_signed_target() {
          name="$1"
          source_path="$2"
          target_path="$3"
          identity="$4"
          source_fingerprint="$5"
          restart_agent="$6"
          marker_path="$target_path.source"
          target_directory=$(/usr/bin/dirname "$target_path")
          target_name=$(/usr/bin/basename "$target_path")
          if [[ "$target_name" == *.app ]]; then
            staging_path="$target_directory/.''${target_name%.app}.new.app"
            backup_path="$target_directory/.''${target_name%.app}.old.app"
          else
            staging_path="$target_path.new"
            backup_path="$target_path.old"
          fi

          identity_line=$(
            /usr/bin/security find-identity -v -p codesigning \
              | /usr/bin/grep -F "\"$identity\"" \
              | /usr/bin/head -n 1 \
              || true
          )
          identity_hash=$(/usr/bin/printf '%s\n' "$identity_line" | /usr/bin/awk '{ print $2 }')
          if [[ -z "$identity_hash" ]]; then
            echo "Missing Code Signing identity for $name: $identity" >&2
            exit 1
          fi
          fingerprint="$source_fingerprint:$identity_hash"

          current_fingerprint=""
          if [[ -f "$marker_path" && ! -L "$marker_path" ]]; then
            current_fingerprint=$(/bin/cat "$marker_path" 2>/dev/null || true)
          fi

          if [[ ( -e "$target_path" || -L "$target_path" ) \
            && "$current_fingerprint" == "$fingerprint" ]] \
            && /usr/bin/codesign --verify --strict "$target_path" 2>/dev/null; then
            return
          fi

          run /bin/mkdir -p "$target_directory"
          run /bin/rm -rf "$staging_path" "$backup_path"
          run /usr/bin/ditto "$source_path" "$staging_path"
          run /bin/chmod -R u+w "$staging_path"
          if ! run /usr/bin/codesign --force --timestamp=none --sign "$identity_hash" "$staging_path"; then
            run /bin/rm -rf "$staging_path"
            exit 1
          fi

          if [[ -e "$target_path" || -L "$target_path" ]]; then
            run /bin/mv "$target_path" "$backup_path"
          fi
          if ! run /bin/mv "$staging_path" "$target_path"; then
            if [[ -e "$backup_path" || -L "$backup_path" ]]; then
              run /bin/mv "$backup_path" "$target_path"
            fi
            exit 1
          fi

          run /bin/rm -rf "$backup_path"
          /usr/bin/printf '%s\n' "$fingerprint" >"$marker_path.new"
          run /bin/rm -f "$marker_path"
          run /bin/mv "$marker_path.new" "$marker_path"

          if [[ -n "$restart_agent" ]]; then
            uid=$(/usr/bin/id -u)
            if /bin/launchctl print "gui/$uid/$restart_agent" >/dev/null 2>&1; then
              run /bin/launchctl kickstart -k "gui/$uid/$restart_agent"
            fi
          fi
        }

        ${installTargets}
      ''
    );
  };
}
