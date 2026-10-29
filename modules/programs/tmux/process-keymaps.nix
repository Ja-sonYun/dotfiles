{
  config,
  lib,
  pkgs,
  ...
}:
let
  tmux = config.programs.tmux;
  cfg = tmux.processKeymaps;
  bindings =
    lib.attrValues tmux.bindings ++ lib.concatMap lib.attrValues (lib.attrValues tmux.keyTables);
  commands = lib.unique (lib.concatMap (b: lib.concatMap (c: c.whenCommand) b.cases) bindings);
  runner = pkgs.writeShellScript "tmux-process-keymap" ''
    export TMUX_KEYMAP_BIN=${lib.escapeShellArg "${tmux.package}/bin/tmux"}
    export TMUX_KEYMAP_PS=${
      lib.escapeShellArg (if pkgs.stdenv.isDarwin then "/bin/ps" else "${pkgs.procps}/bin/ps")
    }
    export TMUX_KEYMAP_SLEEP=${lib.escapeShellArg "${pkgs.coreutils}/bin/sleep"}
    export TMUX_KEYMAP_TARGETS=${lib.escapeShellArg ("|" + lib.concatStringsSep "|" commands + "|")}
    exec ${pkgs.bash}/bin/bash ${tmux.runtime}/scripts/process-keymap "$@"
  '';
  generation = "#{e|+|:#{?@process-keymap-generation,#{@process-keymap-generation},0},1}";
  deferFormats = lib.replaceStrings [ "#" ] [ "##" ];
  transitionCommand =
    target: phase:
    let
      pending = "#{&&:#{==:#{@process-keymap-status},pending},#{==:#{@process-keymap-phase},${phase}}}";
      skip = if phase == "refresh" then "#{==:#{@process-keymap-status},pending}" else pending;
      observe = "${runner} #{q:socket_path} #{q:pane_id} #{q:@process-keymap-generation} ${phase}";
    in
    "if-shell -F -t '${target}' '${deferFormats "#{!:${skip}}"}' { "
    + "set-option -pF -t '${target}' @process-keymap-generation '${deferFormats generation}' ; "
    + "set-option -p -t '${target}' @process-keymap-status pending ; "
    + "set-option -p -t '${target}' @process-keymap-phase ${phase} ; "
    + "set-option -p -t '${target}' @process-keymap-commands '' ; "
    + "set-option -p -t '${target}' @process-keymap-queue '' ; "
    + "run-shell -b -t '${target}' ${lib.escapeShellArg (deferFormats observe)} }";
  invalidateCommand =
    "set-option -pF -t '@target@' @process-keymap-generation '${deferFormats generation}' ; "
    + "set-option -p -t '@target@' @process-keymap-status unknown ; "
    + "set-option -p -t '@target@' @process-keymap-commands '' ; "
    + "set-option -p -t '@target@' @process-keymap-queue ''";
  eventRunner = pkgs.writeShellScript "tmux-process-keymap-event" ''
    socket=$1 target=$2 phase=$3
    [[ -n $target ]] || exit 0
    case $phase in
      start) command=${lib.escapeShellArg (transitionCommand "@target@" "start")} ;;
      prompt) command=${lib.escapeShellArg (transitionCommand "@target@" "prompt")} ;;
      refresh) command=${lib.escapeShellArg (transitionCommand "@target@" "refresh")} ;;
      invalidate) command=${lib.escapeShellArg invalidateCommand} ;;
      *) exit 2 ;;
    esac
    # Keep the event target even if run-shell loses its format context.
    command=''${command//@target@/$target}

    if output=$(${tmux.package}/bin/tmux -S "$socket" run-shell -C -t "$target" "$command" 2>&1); then
      [[ -z $output ]] || printf '%s\n' "$output"
      exit 0
    else
      result=$?
    fi

    # A queued event can outlive its pane, including after target resolution.
    missing_target="^(no such|can't find) (pane|window): [%@][0-9]+$"
    [[ $output =~ $missing_target ]] && exit 0
    printf '%s\n' "$output" >&2
    exit "$result"
  '';
  transition =
    target: phase:
    "if-shell -F '#{!=:${target},}' { run-shell -E ${lib.escapeShellArg "${eventRunner} #{q:socket_path} '${target}' ${phase}"} }";
  bootstrap = pkgs.writeShellScript "tmux-process-keymap-bootstrap" ''
    # Configuration loading has no current pane on the global command queue.
    while IFS= read -r pane; do
      ${eventRunner} "$1" "$pane" refresh
    done < <(${tmux.package}/bin/tmux -S "$1" list-panes -a -F '#{pane_id}')
  '';
  hooks = {
    processKeymapStarted = {
      event = "pane-command-started";
      command = transition "#{hook_pane}" "start";
    };
    processKeymapFinished = {
      event = "pane-command-finished";
      command = transition "#{hook_pane}" "prompt";
    };
    processKeymapPrompt = {
      event = "pane-shell-prompt";
      command = transition "#{hook_pane}" "prompt";
    };
    processKeymapCreated = {
      event = "pane-created";
      command = transition "#{hook_pane}" "start";
    };
    processKeymapDied = {
      event = "pane-died";
      command = transition "#{hook_pane}" "invalidate";
    };
    processKeymapAttached = {
      event = "client-attached";
      command = transition "#{pane_id}" "refresh";
    };
    processKeymapPane = {
      event = "window-pane-changed";
      command = transition "#{hook_pane}" "refresh";
    };
    processKeymapWindow = {
      event = "session-window-changed";
      command = transition "#{hook_window}" "refresh";
    };
  };
in
{
  options.programs.tmux.processKeymaps = {
    enable = lib.mkEnableOption "event-driven foreground process key bindings";
    hookEvents = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      internal = true;
      default = [ "pane-exited" ] ++ map (h: h.event) (lib.attrValues hooks);
      description = "Owned hook events cleared when regenerating the tmux configuration.";
    };
  };

  config = lib.mkIf (tmux.enable && cfg.enable) {
    assertions = [
      {
        assertion = lib.versionAtLeast tmux.package.version "3.8";
        message = "tmux process keymaps require tmux 3.8 or newer.";
      }
      {
        assertion = config.programs.zsh.enable && config.programs.zsh-customize.enable;
        message = "tmux process keymaps require programs.zsh and programs.zsh-customize.";
      }
    ];
    programs = {
      tmux = {
        inherit hooks;
        extraConfig = lib.mkAfter "run-shell -bE '${bootstrap} #{q:socket_path}'";
      };
      zsh-customize.blocks = [
        {
          order = 1090;
          variables._tmux_keymap_command_active = {
            flags = "-gi";
            value = "0";
          };
          functions = {
            _tmux_keymap_preexec = ''
              _tmux_keymap_command_active=1
              printf '\033]133;C\007'
            '';
            _tmux_keymap_precmd = ''
              local command_status=$?
              if (( _tmux_keymap_command_active )); then
                printf '\033]133;D;%d\007' "$command_status"
              fi
              _tmux_keymap_command_active=0
              printf '\033]133;A\007'
            '';
          };
          hooks = {
            preexec = [
              {
                function = "_tmux_keymap_preexec";
                tmuxOnly = true;
              }
            ];
            precmd = [
              {
                function = "_tmux_keymap_precmd";
                tmuxOnly = true;
              }
            ];
          };
        }
      ];
    };
  };
}
