{
  config,
  lib,
  pkgs,
  ...
}:
let
  managed = lib.filterAttrs (_: daemon: daemon.enable != null) config.launchd.externalDaemons;
  applyDaemons = pkgs.writeShellScript "apply-external-daemons" ''
    set -euo pipefail

    ${lib.concatStringsSep "\n" (
      lib.mapAttrsToList (
        name: daemon:
        let
          target = lib.escapeShellArg "system/${name}";
          plist = lib.escapeShellArg daemon.plist;
        in
        if daemon.enable then
          ''
            if [ ! -f ${plist} ]; then
              printf '%s\n' ${lib.escapeShellArg "Missing launchd plist: ${daemon.plist}"} >&2
              exit 1
            fi
            /bin/launchctl enable ${target}
            if ! /bin/launchctl print ${target} >/dev/null 2>&1; then
              /bin/launchctl bootstrap system ${plist}
            fi
            /bin/launchctl kickstart ${target}
          ''
        else
          ''
            /bin/launchctl disable ${target}
            if /bin/launchctl print ${target} >/dev/null 2>&1; then
              /bin/launchctl bootout ${target}
            fi
          ''
      ) managed
    )}
  '';
in
{
  options.launchd.externalDaemons = lib.mkOption {
    default = { };
    description = "Manage existing system launchd services without modifying their plists.";
    type = lib.types.attrsOf (
      lib.types.submodule (
        { name, ... }: {
          options = {
            enable = lib.mkOption {
              type = lib.types.nullOr lib.types.bool;
              default = null;
              description = "Enable and start, or disable and stop; null leaves the service unmanaged.";
            };
            plist = lib.mkOption {
              type = lib.types.addCheck lib.types.str (lib.hasPrefix "/");
              default = "/Library/LaunchDaemons/${name}.plist";
              description = "Absolute path to the installed service plist.";
            };
          };
        }
      )
    );
  };

  config = lib.mkIf (managed != { }) {
    system.activationScripts.postActivation.text = lib.mkAfter ''
      ${applyDaemons} || exit $?
    '';
  };
}
