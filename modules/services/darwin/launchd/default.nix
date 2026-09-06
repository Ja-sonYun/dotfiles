{ lib, ... }:
{
  options.launchd.user.agents = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule (
        { config, name, ... }:
        let
          cfg = config.startupGuard;
          wrapService =
            serviceConfig:
            if !cfg.enable then
              serviceConfig
            else if serviceConfig.Program != null then
              throw "launchd.user.agents.${name}.startupGuard requires Program to be unset."
            else if serviceConfig.ProgramArguments == null || serviceConfig.ProgramArguments == [ ] then
              throw "launchd.user.agents.${name}.startupGuard requires nonempty ProgramArguments."
            else
              let
                arguments = serviceConfig.ProgramArguments;
                executables = [ (builtins.head arguments) ] ++ cfg.extraExecutables;
                files = lib.concatLists (
                  lib.imap0 (
                    index: argument:
                    if !lib.elem argument cfg.readableFileFlags then
                      [ ]
                    else if index + 1 >= builtins.length arguments then
                      throw "launchd.user.agents.${name}.startupGuard: ${argument} requires a file argument."
                    else
                      [ (builtins.elemAt arguments (index + 1)) ]
                  ) arguments
                );
              in
              serviceConfig
              // {
                ProgramArguments = [
                  "/bin/sh"
                  "-c"
                  ''
                    check_paths() {
                      for path in ${lib.escapeShellArgs executables}; do
                        if [ ! -x "$path" ]; then
                          printf '%s\n' "$path"
                          return 1
                        fi
                      done
                      for path in ${lib.escapeShellArgs files}; do
                        if [ ! -r "$path" ]; then
                          printf '%s\n' "$path"
                          return 1
                        fi
                      done
                      return 0
                    }

                    waited=0
                    notified=0
                    while ! missing_path="$(check_paths)"; do
                      printf '%s: waiting for %s\n' ${lib.escapeShellArg name} "$missing_path" >&2
                      if [ "$waited" -ge 60 ] && [ "$notified" -eq 0 ]; then
                        notified=1
                        /usr/bin/osascript \
                          -e 'on run argv' \
                          -e 'display notification "Startup is delayed. Retrying automatically; see the service error log." with title (item 1 of argv)' \
                          -e 'end run' \
                          ${lib.escapeShellArg name} &
                      fi
                      /bin/sleep 10
                      waited=$((waited + 10))
                    done
                    if [ "$waited" -gt 0 ]; then
                      printf '%s: startup paths are ready\n' ${lib.escapeShellArg name} >&2
                    fi
                    exec "$@"
                  ''
                  "${name}-startup-guard"
                ]
                ++ arguments;
              };
        in
        {
          options = {
            startupGuard = {
              enable = lib.mkEnableOption "startup path checks with retry logging and a delayed notification";
              extraExecutables = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                default = [ ];
                description = "Additional paths that must be executable before starting the service.";
              };
              readableFileFlags = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                default = [ ];
                description = "Flags whose following argument must be a readable file before startup.";
              };
            };
            serviceConfig = lib.mkOption {
              apply = wrapService;
            };
          };
        }
      )
    );
  };
}
