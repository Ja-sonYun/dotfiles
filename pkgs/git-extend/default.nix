{
  lib,
  pkgs,
  commands ? [ ],
  ...
}:
let
  quote = lib.escapeShellArg;
  joinPath = path: lib.concatStringsSep " " path;
  sortedCommands = lib.sort (a: b: builtins.length a.path > builtins.length b.path) commands;
  pathTestAt =
    offset: path:
    lib.concatStringsSep " && " (
      lib.imap0 (i: part: ''[ "''${${toString (i + offset)}-}" = ${quote part} ]'') path
    );
  commandHelp =
    command:
    let
      path = joinPath command.path;
    in
    ''printf '  %-24s %s\n' ${quote path} ${quote command.help}'';
  parentPrefixes = lib.unique (
    map (command: lib.init command.path) (
      builtins.filter (command: builtins.length command.path > 1) sortedCommands
    )
  );
  parentCommands =
    prefix:
    builtins.filter (
      command:
      builtins.length command.path > builtins.length prefix
      && lib.take (builtins.length prefix) command.path == prefix
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
      in
      ''
        if ${pathTestAt 1 command.path}; then
            shift ${shiftCount}
            git_extend_cmd_${toString i} "$@"
            exit $?
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
    ) sortedCommands
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

    if [ "''${1-}" = "help" ] && [ "''${2-}" = "custom" ] && [ "$#" -eq 2 ]; then
        printf 'git-extend commands:\n'
    ${allHelp}
        exit 0
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
