{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.tmux-customize;
  esc = lib.escapeShellArg;

  statusType = lib.types.submodule {
    options = {
      enable = lib.mkOption {
        type = lib.types.nullOr lib.types.bool;
        default = null;
        description = "Turn the session status line on/off; null inherits the global setting.";
      };
      position = lib.mkOption {
        type = lib.types.nullOr (
          lib.types.enum [
            "top"
            "bottom"
          ]
        );
        default = null;
      };
      bg = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
      };
      style = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
      };
      left = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
      };
      right = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
      };
    };
  };

  windowType = lib.types.submodule {
    options = {
      format = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
      };
      currentFormat = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
      };
      monitorActivity = lib.mkOption {
        type = lib.types.bool;
        default = false;
      };
      monitorSilence = lib.mkOption {
        type = lib.types.nullOr lib.types.int;
        default = null;
      };
    };
  };

  groupType = lib.types.submodule {
    options = {
      match.env = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Session env marker; if set on a session, it belongs to this group.";
      };
      priority = lib.mkOption {
        type = lib.types.int;
        default = 0;
        description = "Env-match check order (highest first).";
      };
      status = lib.mkOption {
        type = statusType;
        default = { };
      };
      window = lib.mkOption {
        type = windowType;
        default = { };
      };
      menu = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Session @menu value; the menu opener reads it.";
      };
      color = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Section color in the session switcher menu.";
      };
    };
  };

  sessionType = lib.types.submodule {
    options = {
      group = lib.mkOption { type = lib.types.str; };
      label = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
      };
      environment = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
      };
      unicode = lib.mkOption {
        type = lib.types.bool;
        default = false;
      };
    };
  };

  dg = cfg.groups.${cfg.defaultGroup};

  statusCmd = g: side: ''"#(cd #{q:pane_current_path};${tmcStatus} ${g} ${side} #{q:session_name})"'';

  segmentDefs = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (n: body: ''
      seg_${n}() {
      ${body}
      }
    '') cfg.segments
  );

  statusCases = lib.concatStringsSep "\n" (
    lib.concatLists (
      lib.mapAttrsToList (gname: g: [
        "  ${gname}/left) render ${lib.concatStringsSep " " g.status.left} ;;"
        "  ${gname}/right) render ${lib.concatStringsSep " " g.status.right} ;;"
      ]) cfg.groups
    )
  );

  tmcStatus = pkgs.writeShellScript "tmc-status" ''
    group="$1"
    side="$2"
    session="$3"

    ${segmentDefs}

    sep=${esc cfg.separator}

    render() {
      local out="" first=1 s frag
      for s in "$@"; do
        frag="$(seg_"$s")"
        [ -z "$frag" ] && continue
        if [ "$first" -eq 1 ]; then first=0; else out+="$sep"; fi
        out+="$frag"
      done
      printf '%s' "$out"
    }

    case "$group/$side" in
    ${statusCases}
      *) : ;;
    esac
  '';

  envGroups = lib.sort (a: b: a.priority > b.priority) (
    lib.filter (g: g.env != null) (
      lib.mapAttrsToList (n: g: {
        inherit (g) priority;
        name = n;
        env = g.match.env;
      }) cfg.groups
    )
  );

  envChecks = lib.concatMapStringsSep "\n" (
    g:
    ''if tmux show-environment -t "$session" ${g.env} >/dev/null 2>&1; then echo ${g.name}; exit 0; fi''
  ) envGroups;

  exactCases = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (n: s: "  ${n}) echo ${s.group}; exit 0 ;;") cfg.sessions
  );

  encodedCases = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (n: s: "  ${n}|${n}_*) echo ${s.group}; exit 0 ;;") cfg.sessions
  );

  tmcResolveGroup = pkgs.writeShellScript "tmc-resolve-group" ''
    session="$1"
    [ -z "$session" ] && { echo ${cfg.defaultGroup}; exit 0; }

    ${envChecks}

    case "$session" in
    ${exactCases}
    esac

    logical="$session"
    logical="''${logical#_popup_}"
    logical="''${logical#*_}"
    logical="''${logical#git_root_}"
    case "$logical" in
    ${encodedCases}
    esac

    echo ${cfg.defaultGroup}
  '';

  applyFn =
    gname: g:
    let
      st = g.status;
      w = g.window;
      optFrag = name: val: if val == null then "-u ${name}" else "${name} ${esc val}";
      sessionFrags = lib.optional (st.enable != null) "status ${if st.enable then "on" else "off"}" ++ [
        (optFrag "status-position" st.position)
        (optFrag "status-bg" st.bg)
        (optFrag "status-style" st.style)
        "status-left ${statusCmd gname "left"}"
        "status-right ${statusCmd gname "right"}"
        (optFrag "@menu" g.menu)
      ];
      winFrags = [
        (optFrag "window-status-format" w.format)
        (optFrag "window-status-current-format" w.currentFormat)
        "monitor-activity ${if w.monitorActivity then "on" else "off"}"
        (optFrag "monitor-silence" (if w.monitorSilence == null then null else toString w.monitorSilence))
      ];
      chain =
        cmd: target: frags:
        "tmux " + lib.concatMapStringsSep " \\; " (f: ''${cmd} -t "${target}" ${f}'') frags;
    in
    ''
      apply_${gname}() {
        local session="$1" win
        ${chain "set-option" "$session" sessionFrags}
        while IFS= read -r win; do
          [ -z "$win" ] && continue
          ${chain "set-window-option" "$win" winFrags}
        done < <(tmux list-windows -t "$session" -F '#{window_id}' 2>/dev/null)
      }
    '';

  overrideGroups = lib.filterAttrs (n: _: n != cfg.defaultGroup) cfg.groups;

  applyFns = lib.concatStringsSep "\n" (lib.mapAttrsToList applyFn overrideGroups);

  applyCases = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (n: _: ''${n}) apply_${n} "$session" ;;'') overrideGroups
  );

  tmcGroupApply = pkgs.writeShellScript "tmc-group-apply" ''
    pane_id="$1"
    [ -z "$pane_id" ] && pane_id="$TMUX_PANE"
    [ -z "$pane_id" ] && exit 0
    session="$(tmux display-message -pt "$pane_id" '#{session_name}' 2>/dev/null)"
    [ -z "$session" ] && exit 0

    ${applyFns}

    group="$(${tmcResolveGroup} "$session")"
    case "$group" in
    ${applyCases}
    esac
  '';

  groupColorCases = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (
      n: g: "  ${n}) printf '%s' ${esc (if g.color == null then "white" else g.color)} ;;"
    ) cfg.groups
  );

  labelExactCases = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (
      n: s: "  ${n}) printf '%s' ${esc (if s.label == null then n else s.label)}; return ;;"
    ) cfg.sessions
  );

  labelEncodedCases = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (
      n: s:
      ''${n}|${n}_*) printf '%s (%s)' ${esc (if s.label == null then n else s.label)} "$base"; return ;;''
    ) cfg.sessions
  );

  groupNamesList = lib.concatStringsSep " " (lib.attrNames cfg.groups);

  tmcSessionMenu = pkgs.writeShellScript "tmc-session-menu" ''
    tmp="/tmp/tmc-session-menu.yaml"
    {
      printf 'title: " sessions "\n'
      printf 'border: "simple"\n'
      printf 'items:\n'
    } > "$tmp"

    group_color() {
      case "$1" in
    ${groupColorCases}
        *) printf '%s' white ;;
      esac
    }

    label_for() {
      local s="$1" logical base
      case "$s" in
    ${labelExactCases}
      esac
      logical="''${s#_popup_}"
      logical="''${logical#*_}"
      logical="''${logical#git_root_}"
      base="''${logical##*_}"
      case "$logical" in
    ${labelEncodedCases}
      esac
      printf '%s' "$s"
    }

    emit_item() {
      local s="$1" name
      name="$(label_for "$s")"
      {
        printf '  - Menu:\n'
        printf '      name: "%s"\n' "$name"
        printf '      shortcut: ""\n'
        printf '      command: "tmux switch-client -t \\"%s\\""\n' "$s"
        printf '      close_after_command: true\n'
      } >> "$tmp"
    }

    all="$(tmux list-sessions -F '#{session_name}' 2>/dev/null)"
    for g in ${groupNamesList}; do
      header_done=0
      while IFS= read -r s; do
        [ -z "$s" ] && continue
        [ "$(${tmcResolveGroup} "$s")" = "$g" ] || continue
        if [ "$header_done" -eq 0 ]; then
          printf '  - NoDim:\n      name: "#[fg=%s] %s "\n' "$(group_color "$g")" "$g" >> "$tmp"
          header_done=1
        fi
        emit_item "$s"
      done <<< "$all"
    done

    tmux-menu show --menu "$tmp"
  '';

  startCmds = lib.concatMapStringsSep "\n" (
    name:
    let
      s = cfg.sessions.${name};
      envFlags = lib.concatStringsSep " " (
        lib.mapAttrsToList (k: v: "-e ${esc "${k}=${v}"}") s.environment
      );
    in
    "tmux ${lib.optionalString s.unicode "-u "}new-session ${
      lib.optionalString (name != cfg.launcher.attach) "-d "
    }${envFlags} -s ${name} 2>/dev/null"
  ) cfg.launcher.startSessions;

  resetLines = lib.concatStringsSep "\n" cfg.launcher.reset;

  tmcTmux = pkgs.writeShellScript "tmc-tmux" ''
    init_tmux() {
    ${startCmds}
    ${resetLines}
    }

    cd "$HOME" || exit 1
    init_tmux || tmux -u attach -t ${cfg.launcher.attach}
  '';

  defaultStatusOpts =
    lib.optionalAttrs (dg.status.position != null) { status-position = dg.status.position; }
    // lib.optionalAttrs (dg.status.bg != null) { status-bg = ''"${dg.status.bg}"''; }
    // lib.optionalAttrs (dg.status.style != null) { status-style = ''"${dg.status.style}"''; }
    // {
      status-left = statusCmd cfg.defaultGroup "left";
      status-right = statusCmd cfg.defaultGroup "right";
    };

  defaultWindowOpts =
    lib.optionalAttrs (dg.window.format != null) { window-status-format = ''"${dg.window.format}"''; }
    // lib.optionalAttrs (dg.window.currentFormat != null) {
      window-status-current-format = ''"${dg.window.currentFormat}"'';
    };

  applyHook = event: {
    inherit event;
    command = ''run-shell "${tmcGroupApply} #{pane_id}"'';
  };
in
{
  options.programs.tmux-customize = {
    enable = lib.mkEnableOption "tmux-customize";

    segments = lib.mkOption {
      type = lib.types.attrsOf lib.types.lines;
      default = { };
      description = "Named shell snippets printing a status fragment.";
    };

    separator = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "String joined between rendered segments.";
    };

    defaultGroup = lib.mkOption {
      type = lib.types.str;
      description = "Group used as the global default and fallback.";
    };

    groups = lib.mkOption {
      type = lib.types.attrsOf groupType;
      default = { };
    };

    sessions = lib.mkOption {
      type = lib.types.attrsOf sessionType;
      default = { };
      description = "Named session registry: logical name -> group (+ bootstrap env/unicode).";
    };

    launcher = {
      enable = lib.mkEnableOption "the tmc-tmux bootstrap launcher (aliased as tm)";
      startSessions = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Session names (keys of sessions) created on startup, in order.";
      };
      attach = lib.mkOption {
        type = lib.types.str;
        default = "main";
        description = "Session attached to as fallback.";
      };
      reset = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [
          "rm -f /tmp/tmux-popup-loc.json"
          ''rm -rf "''${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/agent-status"''
        ];
        description = "Shell commands run on cold start to clear stale state.";
      };
    };

    sessionMenuScript = lib.mkOption {
      type = lib.types.path;
      readOnly = true;
      internal = true;
      description = "Generated session switcher script (parses tmux ls into a menu).";
    };
  };

  config = lib.mkIf cfg.enable {
    programs.tmux-customize.sessionMenuScript = tmcSessionMenu;

    programs.tmux.setGlobalOptions = defaultStatusOpts;
    programs.tmux.setWindowOptions = defaultWindowOpts;

    programs.tmux.hooks = {
      tmcGroupApplyNewSession = applyHook "after-new-session";
      tmcGroupApplyNewWindow = applyHook "after-new-window";
      tmcGroupApplyClientAttached = applyHook "client-attached";
      tmcGroupApplyClientSessionChanged = applyHook "client-session-changed";
    };

    home.shellAliases = lib.optionalAttrs cfg.launcher.enable { tm = toString tmcTmux; };
  };
}
