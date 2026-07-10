{
  lib,
  pkgs,
  commands ? [ ],
  ...
}:
let
  quote = lib.escapeShellArg;
  joinPath = path: lib.concatStringsSep " " path;
  commandFlag = command: command.flag or null;
  hasFlag = command: commandFlag command != null;
  commandLabel =
    command:
    let
      flag = commandFlag command;
    in
    joinPath (command.path ++ lib.optionals (flag != null) [ flag ]);
  sortedCommands = lib.sort (a: b: builtins.length a.path > builtins.length b.path) commands;
  pathTestAt =
    offset: path:
    lib.concatStringsSep " && " (
      lib.imap0 (i: part: ''[ "''${${toString (i + offset)}-}" = ${quote part} ]'') path
    );
  commandHelp =
    command:
    let
      path = commandLabel command;
    in
    ''printf '  %-24s %s\n' ${quote path} ${quote command.help}'';
  parentPrefixes = lib.unique (
    map (command: if hasFlag command then command.path else lib.init command.path) (
      builtins.filter (command: hasFlag command || builtins.length command.path > 1) sortedCommands
    )
  );
  parentCommands =
    prefix:
    builtins.filter (
      command:
      let
        prefixLength = builtins.length prefix;
        pathLength = builtins.length command.path;
      in
      lib.take prefixLength command.path == prefix
      && (pathLength > prefixLength || (hasFlag command && pathLength == prefixLength))
    ) sortedCommands;
  parentHelp =
    prefix:
    let
      prefixLength = builtins.length prefix;
      items = map (
        command:
        let
          rest = lib.drop prefixLength command.path;
        in
        command // { path = rest; }
      ) (parentCommands prefix);
    in
    lib.concatStringsSep "\n" (map commandHelp items);
  commandFunctions = lib.concatStringsSep "\n\n" (
    lib.imap0 (i: command: ''
      git_extend_cmd_${toString i}() {
          if [ "''${1-}" = "-h" ] || [ "''${1-}" = "--help" ]; then
              printf '%s\n' ${quote command.help}
              return 0
          fi

      ${command.command}
      }
    '') sortedCommands
  );
  commandDispatch = lib.concatStringsSep "\n" (
    lib.imap0 (
      i: command:
      let
        shiftCount = toString (builtins.length command.path);
        flag = commandFlag command;
      in
      if flag == null then
        ''
          if ${pathTestAt 1 command.path}; then
              shift ${shiftCount}
              git_extend_cmd_${toString i} "$@"
              exit $?
          fi
        ''
      else
        ''
          if ${pathTestAt 1 command.path}; then
              git_extend_original_args=("$@")
              shift ${shiftCount}
              git_extend_args=()
              git_extend_matched=0
              git_extend_flag_index=-1
              git_extend_index=0

              for git_extend_arg in "$@"; do
                  if [ "$git_extend_arg" = ${quote flag} ]; then
                      if [ "$git_extend_matched" -eq 0 ]; then
                          git_extend_flag_index=$git_extend_index
                      fi
                      git_extend_matched=1
                      git_extend_index=$((git_extend_index + 1))
                      continue
                  fi

                  git_extend_args+=("$git_extend_arg")
                  git_extend_index=$((git_extend_index + 1))
              done

              if [ "$git_extend_matched" -eq 1 ]; then
                  GIT_EXTEND_FLAG_INDEX="$git_extend_flag_index" git_extend_cmd_${toString i} "''${git_extend_args[@]}"
                  exit $?
              fi

              set -- "''${git_extend_original_args[@]}"
          fi
        ''
    ) sortedCommands
  );
  exactHelpDispatch = lib.concatStringsSep "\n" (
    map (
      command:
      let
        argCount = toString (builtins.length command.path + 1);
      in
      ''
        if [ "$#" -eq ${argCount} ] && ${pathTestAt 2 command.path}; then
            printf '%s\n' ${quote command.help}
            exit 0
        fi
      ''
    ) (builtins.filter (command: !hasFlag command) sortedCommands)
  );
  parentHelpDispatch = lib.concatStringsSep "\n" (
    map (
      prefix:
      let
        argCount = toString (builtins.length prefix + 1);
        helpArg = toString (builtins.length prefix + 1);
        realGitArgs = lib.concatStringsSep " " (map quote prefix);
        helpBody = parentHelp prefix;
      in
      ''
        if [ "$#" -eq ${argCount} ] && ${pathTestAt 1 prefix} && { [ "''${${helpArg}-}" = "-h" ] || [ "''${${helpArg}-}" = "--help" ] || [ "''${${helpArg}-}" = "help" ]; }; then
            set +e
            "$real_git" ${realGitArgs} -h
            rc=$?
            set -e
            printf '\ngit-extend commands:\n'
        ${helpBody}
            exit "$rc"
        fi
        if [ "$#" -eq ${argCount} ] && [ "''${1-}" = "help" ] && ${pathTestAt 2 prefix}; then
            set +e
            "$real_git" ${realGitArgs} -h
            rc=$?
            set -e
            printf '\ngit-extend commands:\n'
        ${helpBody}
            exit "$rc"
        fi
      ''
    ) parentPrefixes
  );
  allHelp = lib.concatStringsSep "\n" (map commandHelp sortedCommands);
  gitExtendScript = ''
    set -euo pipefail

    real_git=${quote "${pkgs.git}/bin/git"}

    git() {
        "$real_git" "$@"
    }

    ${commandFunctions}

    if { [ "''${1-}" = "checkout" ] || [ "''${1-}" = "co" ] || [ "''${1-}" = "switch" ]; } &&
       git_dir="$("$real_git" rev-parse --absolute-git-dir 2>/dev/null)" &&
       common_dir="$("$real_git" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" &&
       [ "$git_dir" != "$common_dir" ]; then
        case "''${1-}:''${2-}" in
            checkout: | co: | checkout:-h | checkout:--help | co:-h | co:--help | switch:-h | switch:--help | checkout:-- | co:--) ;;
            *)
                printf "error: branch switching is disabled in linked worktrees; use 'git worktree checkout <branch>' or 'git checkout -- <path>'\n" >&2
                exit 1
                ;;
        esac
    fi

    if [ "''${1-}" = "help" ] && [ "''${2-}" = "custom" ] && [ "$#" -eq 2 ]; then
        printf 'git-extend commands:\n'
    ${allHelp}
        exit 0
    fi

    if [ "$#" -eq 1 ] && { [ "''${1-}" = "-h" ] || [ "''${1-}" = "--help" ] || [ "''${1-}" = "help" ]; }; then
        set +e
        "$real_git" "$1"
        rc=$?
        set -e
        printf '\ngit-extend commands:\n'
    ${allHelp}
        exit "$rc"
    fi

    if [ "''${1-}" = "help" ]; then
    ${exactHelpDispatch}
    ${parentHelpDispatch}
    fi

    ${parentHelpDispatch}
    ${commandDispatch}

    exec "$real_git" "$@"
  '';
  gitBin = pkgs.writeShellScriptBin "git" gitExtendScript;
in
pkgs.symlinkJoin {
  name = "git-extend";
  paths = [ gitBin ];
}
