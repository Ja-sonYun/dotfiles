{
  lib,
  pkgs,
  commands ? [ ],
  restrictLinkedWorktreeBranchSwitching ? false,
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
  hookedGit = pkgs.command.hook {
    package = pkgs.git;
    binary = "git";
    hooks = map (
      command:
      command
      // {
        command = ''
          git() {
              command_hook_original "$@"
          }

          ${command.command}
        '';
      }
    ) commands;
  };
  gitExtendScript = ''
    set -euo pipefail

    real_git=${quote "${pkgs.git}/bin/git"}

    git_args=("$@")
    global_args=()
    preserve_git_dir="''${GIT_DIR+x}"
    command_index=0
    while [ "$command_index" -lt "''${#git_args[@]}" ]; do
        arg="''${git_args[$command_index]}"
        case "$arg" in
            --git-dir | --git-dir=* | --bare) preserve_git_dir=x ;;
        esac
        case "$arg" in
            -C | -c | --git-dir | --work-tree | --namespace | --config-env | --super-prefix)
                global_args+=("$arg")
                command_index=$((command_index + 1))
                [ "$command_index" -lt "''${#git_args[@]}" ] || break
                global_args+=("''${git_args[$command_index]}")
                ;;
            --)
                exec "$real_git" "$@"
                ;;
            -*) global_args+=("$arg") ;;
            *) break ;;
        esac
        command_index=$((command_index + 1))
    done

    if [ "$command_index" -gt 0 ] && [ "$command_index" -lt "''${#git_args[@]}" ]; then
        dispatch_path="$0"
        [[ "$dispatch_path" = /* ]] || dispatch_path="$PWD/$dispatch_path"
        # Let Git export global configuration; discard only the Git directory inferred by its shell alias.
        # https://github.com/git/git/blob/master/git.c
        exec "$real_git" "''${global_args[@]}" \
            -c 'alias.dotfiles-dispatch=!f() {
                cd -- "''${GIT_PREFIX:-.}" || exit
                [ "$1" = x ] || unset GIT_DIR
                shift
                exec "$@"
            }; f' \
            dotfiles-dispatch "$preserve_git_dir" "$dispatch_path" "''${git_args[@]:command_index}"
    fi

    ${lib.optionalString restrictLinkedWorktreeBranchSwitching ''
      git_command="''${git_args[$command_index]-}"
      first_argument="''${git_args[$((command_index + 1))]-}"
      if { [ "$git_command" = "checkout" ] || [ "$git_command" = "co" ] || [ "$git_command" = "switch" ]; } &&
         git_dir="$("$real_git" "''${global_args[@]}" rev-parse --absolute-git-dir 2>/dev/null)" &&
         common_dir="$("$real_git" "''${global_args[@]}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" &&
         [ "$git_dir" != "$common_dir" ]; then
          allow_checkout=false
          case "$git_command:$first_argument" in
              checkout: | co: | checkout:-h | checkout:--help | co:-h | co:--help | switch:-h | switch:--help)
                  allow_checkout=true
                  ;;
              checkout:* | co:*)
                  argument_index=$((command_index + 1))
                  safe_options=true
                  patch_restore=false
                  while [ "$argument_index" -lt "''${#git_args[@]}" ]; do
                      arg="''${git_args[$argument_index]}"
                      case "$arg" in
                          --)
                              if [ "$((argument_index + 1))" -lt "''${#git_args[@]}" ]; then
                                  allow_checkout=true
                              fi
                              break
                              ;;
                          -p | --patch) patch_restore=true ;;
                          -q | --quiet | -f | --force | -m | --merge | --ours | --theirs | --overlay | --no-overlay | --ignore-skip-worktree-bits | --conflict=*) ;;
                          --conflict)
                              argument_index=$((argument_index + 1))
                              if [ "$argument_index" -ge "''${#git_args[@]}" ]; then
                                  safe_options=false
                                  break
                              fi
                              ;;
                          -*)
                              safe_options=false
                              break
                              ;;
                      esac
                      argument_index=$((argument_index + 1))
                  done
                  if [ "$safe_options" = true ] && [ "$patch_restore" = true ]; then
                      allow_checkout=true
                  fi
                  ;;
          esac
          if [ "$allow_checkout" != true ]; then
              printf "error: branch switching is disabled in linked worktrees; use 'git worktree checkout <branch>' or 'git checkout -- <path>'\n" >&2
              exit 1
          fi
      fi
    ''}

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
        :
    ${exactHelpDispatch}
    fi

    ${parentHelpDispatch}

    exec ${hookedGit}/bin/git "$@"
  '';
  gitBin = pkgs.writeShellScriptBin "git" gitExtendScript;
in
pkgs.symlinkJoin {
  name = "git-extend";
  paths = [ gitBin ];
  postBuild = ''
    ln -s git "$out/bin/,git"
  '';
}
