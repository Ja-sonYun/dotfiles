{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.tmux;
  loggingLibrary = pkgs.writeText "tmux-logging" (
    (
      if config.programs.logging.enable then
        ''
          TMUX_LOG_SOCKET=${lib.escapeShellArg config.programs.logging.socketPath}
          if ! enable -f ${lib.escapeShellArg config.programs.logging.bashLibrary} dotfiles_log 2>/dev/null; then
            TMUX_LOG_SOCKET=""
          fi
        ''
      else
        ''
          TMUX_LOG_SOCKET=""
        ''
    )
    + builtins.readFile ./scripts/lib/logging
  );
  runtime = pkgs.runCommand "tmux-agent-runtime" { nativeBuildInputs = [ pkgs.bash ]; } ''
    mkdir -p $out/extensions/agent $out/extensions/popup
    cp -R ${./scripts} $out/scripts
    cp -R ${./extensions/agent/scripts} $out/extensions/agent/scripts
    cp -R ${./extensions/popup/scripts} $out/extensions/popup/scripts
    chmod -R u+w $out
    cp ${loggingLibrary} $out/scripts/lib/logging
    patchShebangs --host $out
  '';

  caseType = lib.types.submodule {
    options = {
      whenEnv = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Required session environment variables.";
      };
      unlessEnv = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Session environment variables that must be unset.";
      };
      match = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Additional shell condition.";
      };
      whenFormat = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Additional tmux format condition.";
      };
      command = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "tmux command for this case.";
      };
      script = lib.mkOption {
        type = lib.types.nullOr lib.types.lines;
        default = null;
        description = "Shell script for this case.";
      };
    };
  };

  bindingOptions = name: {
    key = lib.mkOption {
      type = lib.types.str;
      default = name;
      description = "Key combination.";
    };
    repeat = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Allow key repeats.";
    };
    command = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "tmux command for this binding.";
    };
    script = lib.mkOption {
      type = lib.types.nullOr lib.types.lines;
      default = null;
      description = "Shell script for this binding.";
    };
    cases = lib.mkOption {
      type = lib.types.listOf caseType;
      default = [ ];
      description = "Conditional bindings; first match wins.";
    };
    noDefault = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Disable the default binding when no case matches.";
    };
  };

  bindingType = lib.types.submodule (
    { name, ... }:
    {
      options = bindingOptions name // {
        table = lib.mkOption {
          type = lib.types.enum [
            "prefix"
            "root"
            "copy-mode-vi"
          ];
          default = "prefix";
          description = "Key table.";
        };
      };
    }
  );

  keyTableBindingType = lib.types.submodule (
    { name, ... }:
    {
      options = bindingOptions name;
    }
  );

  # < and > omitted: their '' breaks if-shell single-quote wrapping.
  keyDefaults = {
    "Space" = "next-layout";
    "!" = "break-pane";
    "'\"'" = "split-window";
    "#" = "list-buffers";
    "$" = ''command-prompt -I "#S" { rename-session "%%" }'';
    "%" = "split-window -h";
    "&" = ''confirm-before -p "kill-window #W? (y/n)" kill-window'';
    "'" = ''command-prompt -T window-target -p index { select-window -t ":%%" }'';
    "(" = "switch-client -p";
    ")" = "switch-client -n";
    "*" = "new-pane";
    "," = ''command-prompt -I "#W" { rename-window "%%" }'';
    "-" = "delete-buffer";
    "." = ''command-prompt -T target { move-window -t "%%" }'';
    "/" = ''command-prompt -k -p key { list-keys -1N "%%" }'';
    "0" = "select-window -t :=0";
    "1" = "select-window -t :=1";
    "2" = "select-window -t :=2";
    "3" = "select-window -t :=3";
    "4" = "select-window -t :=4";
    "5" = "select-window -t :=5";
    "6" = "select-window -t :=6";
    "7" = "select-window -t :=7";
    "8" = "select-window -t :=8";
    "9" = "select-window -t :=9";
    ":" = "command-prompt";
    ";" = "last-pane";
    "=" = "choose-buffer -Z";
    "?" = "list-keys -N";
    "@" = ''if-shell -F "#{pane_floating_flag}" { join-pane } { break-pane -W }'';
    "C" = "customize-mode -Z";
    "D" = "choose-client -Z";
    "E" = "select-layout -E";
    "L" = "switch-client -l";
    "M" = "select-pane -M";
    "[" = "copy-mode";
    "]" = "paste-buffer -p";
    "c" = "new-window";
    "d" = "detach-client";
    "f" = ''command-prompt { find-window -Z "%%" }'';
    "g" = "switch-client -Tmove";
    "i" = "display-message";
    "l" = "last-window";
    "m" = "select-pane -m";
    "n" = "next-window";
    "o" = "select-pane -t :.+";
    "p" = "previous-window";
    "q" = "display-panes";
    "r" = "refresh-client";
    "s" = "choose-tree -Zs";
    "t" = "clock-mode";
    "w" = "choose-tree -Zw";
    "x" = ''confirm-before -p "kill-pane #P? (y/n)" kill-pane'';
    "z" = "resize-pane -Z";
    "{" = "swap-pane -U";
    "}" = "swap-pane -D";
    "~" = "show-messages";
    "DC" = "refresh-client -c";
    "PPage" = "copy-mode -u";
    "Up" = "select-pane -U";
    "Down" = "select-pane -D";
    "Left" = "select-pane -L";
    "Right" = "select-pane -R";
    "M-1" = "select-layout even-horizontal";
    "M-2" = "select-layout even-vertical";
    "M-3" = "select-layout main-horizontal";
    "M-4" = "select-layout main-vertical";
    "M-5" = "select-layout tiled";
    "M-6" = "select-layout main-horizontal-mirrored";
    "M-7" = "select-layout main-vertical-mirrored";
    "M-n" = "next-window -a";
    "M-o" = "rotate-window -D";
    "M-p" = "previous-window -a";
    "M-Up" = "resize-pane -U 5";
    "M-Down" = "resize-pane -D 5";
    "M-Left" = "resize-pane -L 5";
    "M-Right" = "resize-pane -R 5";
    "C-b" = "send-prefix";
    "C-o" = "rotate-window";
    "C-z" = "suspend-client";
    "C-Up" = "resize-pane -U";
    "C-Down" = "resize-pane -D";
    "C-Left" = "resize-pane -L";
    "C-Right" = "resize-pane -R";
    "S-Up" = "refresh-client -U 10";
    "S-Down" = "refresh-client -D 10";
    "S-Left" = "refresh-client -L 10";
    "S-Right" = "refresh-client -R 10";
  };

  hookType = lib.types.submodule {
    options = {
      event = lib.mkOption {
        type = lib.types.str;
        description = "Hook event.";
      };
      command = lib.mkOption {
        type = lib.types.str;
        description = "Hook command.";
      };
    };
  };

  unbindType = lib.types.submodule {
    options = {
      key = lib.mkOption {
        type = lib.types.str;
        description = "Key to unbind.";
      };
      table = lib.mkOption {
        type = lib.types.nullOr (
          lib.types.enum [
            "prefix"
            "root"
            "copy-mode-vi"
          ]
        );
        default = "prefix";
        description = "Key table override.";
      };
    };
  };

  tableFlag = t: if t == "root" then "-n" else "-T ${t}";

  renderSet = prefix: lib.mapAttrsToList (k: v: "${prefix} ${k} ${v}");

  caseGuard =
    c:
    lib.foldl' (acc: value: if acc == "" then value else "#{&&:${acc},${value}}") "" (
      (map (e: "#{!=:#{E:${e}},}") c.whenEnv)
      ++ (map (e: "#{==:#{E:${e}},}") c.unlessEnv)
      ++ lib.optional (c.whenFormat != null) c.whenFormat
    );

  caseAct =
    name: i: c:
    if c.script != null then
      "run-shell ${pkgs.writeShellScript "tmux-key-${name}-${toString i}" c.script}"
    else
      c.command;

  renderBinding =
    name: b:
    let
      guarded = lib.filter (c: caseGuard c != "" || c.match != null) b.cases;
      defaultCase = lib.findFirst (c: caseGuard c == "" && c.match == null) null b.cases;
      defaultAct =
        if defaultCase != null then
          caseAct name "d" defaultCase
        else if b.noDefault then
          null
        else
          keyDefaults.${b.key} or null;
      chain = lib.foldr (
        e: acc:
        let
          fallback = lib.optionalString (acc != null) " { ${acc} }";
          action =
            if e.c.match == null then
              caseAct name e.i e.c
            else
              "if-shell ${lib.escapeShellArg e.c.match} { ${caseAct name e.i e.c} }${fallback}";
        in
        if caseGuard e.c == "" then
          action
        else
          "if-shell -F ${lib.escapeShellArg (caseGuard e.c)} { ${action} }${fallback}"
      ) defaultAct (lib.imap0 (i: c: { inherit i c; }) guarded);
      action =
        if b.cases == [ ] then
          if b.script != null then
            "run-shell ${pkgs.writeShellScript "tmux-key-${name}" b.script}"
          else
            b.command
        else
          chain;
    in
    assert lib.assertMsg
      (
        if b.cases == [ ] then
          (b.command != null) != (b.script != null)
        else
          b.command == null && b.script == null
      )
      "programs.tmux binding ${name}: use exactly one of command/script (no cases) OR cases (no command/script)";
    lib.concatStringsSep " " (
      [
        "bind-key"
        (tableFlag b.table)
      ]
      ++ lib.optional b.repeat "-r"
      ++ [
        b.key
        action
      ]
    );

  renderUnbind = u: "unbind-key ${lib.optionalString (u.table != null) "-T ${u.table} "}${u.key}";

  renderKeyTable =
    table: bindings:
    lib.mapAttrsToList (
      name: binding: renderBinding "${table}-${name}" (binding // { inherit table; })
    ) bindings;

  renderHooks =
    hooks:
    let
      entries = lib.attrValues hooks;
      events = lib.unique (map (h: h.event) entries);
      unsets = map (e: "set-hook -gu ${e}") events;
      appends = map (h: "set-hook -ga ${h.event} '${h.command}'") entries;
    in
    unsets ++ appends;

  vimNavLines =
    let
      mk =
        k: dir:
        "bind -n C-${k} if-shell -F '#{==:#{pane_current_command},vim}' 'send-keys C-${k}' 'select-pane -${dir}'";
    in
    [
      (mk "h" "L")
      (mk "j" "D")
      (mk "k" "U")
      (mk "l" "R")
      "bind-key -T copy-mode-vi 'C-h' select-pane -L"
      "bind-key -T copy-mode-vi 'C-j' select-pane -D"
      "bind-key -T copy-mode-vi 'C-k' select-pane -U"
      "bind-key -T copy-mode-vi 'C-l' select-pane -R"
      ''bind-key -T copy-mode-vi 'C-\' select-pane -l''
    ];

  configText = lib.concatStringsSep "\n" (
    lib.concatLists [
      (renderSet "set -sg" cfg.setServerOptions)
      (renderSet "set -g" cfg.setGlobalOptions)
      (renderSet "set-window-option -g" cfg.setWindowOptions)
      (lib.optionals cfg.enableVimIntegration vimNavLines)
      (renderHooks cfg.hooks)
      (map renderUnbind cfg.unbind)
      (lib.mapAttrsToList renderBinding cfg.bindings)
      (lib.concatLists (lib.mapAttrsToList renderKeyTable cfg.keyTables))
      (lib.optional (cfg.extraConfig != "") cfg.extraConfig)
    ]
  );
in
{
  imports = [ ./extensions ];

  disabledModules = [ "programs/tmux.nix" ];

  options.programs.tmux = {
    enable = lib.mkEnableOption "tmux";

    loggingShell = lib.mkOption {
      type = lib.types.lines;
      readOnly = true;
      default = "source ${loggingLibrary}";
      description = "Shell helpers using the shared logger's Bash builtin and socket.";
    };
    runtime = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = runtime;
      description = "Agent and popup scripts with configured logging and a matching Nix Bash interpreter.";
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.tmux;
      description = "tmux package.";
    };

    setGlobalOptions = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Global session options.";
    };

    setWindowOptions = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Global window options.";
    };

    setServerOptions = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Server options.";
    };

    enableVimIntegration = lib.mkEnableOption "Vim-aware pane navigation";

    bindings = lib.mkOption {
      type = lib.types.attrsOf bindingType;
      default = { };
      description = "Named key bindings.";
    };

    keyTables = lib.mkOption {
      type = lib.types.attrsOf (lib.types.attrsOf keyTableBindingType);
      default = { };
      description = "Custom key tables.";
    };

    hooks = lib.mkOption {
      type = lib.types.attrsOf hookType;
      default = { };
      description = "Named hooks.";
    };

    unbind = lib.mkOption {
      type = lib.types.listOf unbindType;
      default = [ ];
      description = "Keys to unbind.";
    };

    extraConfig = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = "Additional tmux configuration.";
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ cfg.package ];
    home.file.".tmux.conf".text = configText + "\n";
  };
}
