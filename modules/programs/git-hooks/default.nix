{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.gitHooks;
  hooks = lib.filterAttrs (_: tasks: tasks != { }) cfg.hooks;
  makeHook =
    hook: tasks:
    let
      readsStdin = builtins.elem hook [
        "pre-push"
        "pre-receive"
        "post-receive"
        "post-rewrite"
        "reference-transaction"
      ];
      runTask =
        name: script:
        let
          executable = pkgs.writeShellScript "git-hook-task" script;
        in
        ''
          if ${executable} "$@"${lib.optionalString readsStdin " < \"$input\""}; then
            :
          else
            status=$?
            printf '%s (exit %s)\n' ${lib.escapeShellArg "Git hook ${hook}/${name} failed"} "$status" >&2
            ${if lib.hasPrefix "post-" hook then "result=$status" else "exit \"$status\""}
          fi
        '';
    in
    pkgs.writeShellScript "git-hook-${hook}" (
      lib.optionalString readsStdin ''
        input=$(${pkgs.coreutils}/bin/mktemp) || exit 1
        trap '${pkgs.coreutils}/bin/rm -f "$input"' EXIT
        ${pkgs.coreutils}/bin/cat > "$input" || exit 1
      ''
      + ''
        result=0
        ${lib.concatStringsSep "\n" (lib.mapAttrsToList runTask tasks)}
        exit "$result"
      ''
    );
  hooksDirectory = pkgs.linkFarm "git-hooks" (
    lib.mapAttrsToList (hook: tasks: {
      name = hook;
      path = makeHook hook tasks;
    }) hooks
  );
in
{
  options.programs.gitHooks.hooks = lib.mkOption {
    type = lib.types.attrsOf (lib.types.attrsOf lib.types.lines);
    default = { };
    description = ''
      Git hook scripts keyed by hook name, then task name. Tasks run in
      alphabetical name order in separate processes with Git's arguments.
      Post hooks continue after failures; other hooks stop at the first failure.
      Repository-local core.hooksPath settings override this global directory.
    '';
  };

  config = lib.mkIf (hooks != { }) {
    programs.git.settings.core.hooksPath = toString hooksDirectory;
  };
}
