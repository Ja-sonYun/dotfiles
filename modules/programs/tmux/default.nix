{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.tmux;

  caseType = lib.types.submodule {
    options = {
      whenEnv = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Guard: all these session env vars must be set.";
      };
      unlessEnv = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Guard: all these session env vars must be unset.";
      };
      match = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Extra raw if-shell condition, AND-ed with the env guards.";
      };
      command = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "tmux command for this case. Exclusive with script.";
      };
      script = lib.mkOption {
        type = lib.types.nullOr lib.types.lines;
        default = null;
        description = "Inline shell for this case; run via run-shell.";
      };
    };
  };

  bindingOptions = name: {
    key = lib.mkOption {
      type = lib.types.str;
      default = name;
      description = "Key spec emitted verbatim to bind-key; defaults to the attribute name.";
    };
    repeat = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Add -r (repeatable).";
    };
    command = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Unconditional tmux command; use \\; to chain. Exclusive with script/cases.";
    };
    script = lib.mkOption {
      type = lib.types.nullOr lib.types.lines;
      default = null;
      description = "Unconditional inline shell; run via run-shell. Exclusive with command/cases.";
    };
    cases = lib.mkOption {
      type = lib.types.listOf caseType;
      default = [ ];
      description = "Ordered env-guarded branches (first match wins); a guardless case is the default else.";
    };
    noDefault = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "When cases are used and none match: do nothing instead of the key's tmux default.";
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
          description = "Key table: root -> -n, others -> -T <table>.";
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
        description = "Hook event, e.g. after-new-window.";
      };
      command = lib.mkOption {
        type = lib.types.str;
        description = "Command run by the hook.";
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
        description = "Table; null omits -T.";
      };
    };
  };

  tableFlag = t: if t == "root" then "-n" else "-T ${t}";

  renderSet = prefix: lib.mapAttrsToList (k: v: "${prefix} ${k} ${v}");

  caseGuard =
    c:
    lib.concatStringsSep " && " (
      (map (e: "tmux show-environment ${e} >/dev/null 2>&1") c.whenEnv)
      ++ (map (e: "! tmux show-environment ${e} >/dev/null 2>&1") c.unlessEnv)
      ++ lib.optional (c.match != null) c.match
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
      guarded = lib.filter (c: caseGuard c != "") b.cases;
      defaultCase = lib.findFirst (c: caseGuard c == "") null b.cases;
      defaultAct =
        if defaultCase != null then
          caseAct name "d" defaultCase
        else if b.noDefault then
          null
        else
          keyDefaults.${b.key} or null;
      chain = lib.foldr (
        e: acc:
        "if-shell '${caseGuard e.c}' { ${caseAct name e.i e.c} }${
          lib.optionalString (acc != null) " { ${acc} }"
        }"
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
  disabledModules = [ "programs/tmux.nix" ];

  options.programs.tmux = {
    enable = lib.mkEnableOption "tmux (custom module)";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.tmux;
      description = "tmux package to install.";
    };

    agentStatusScript = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      internal = true;
      description = "Agent status script path.";
    };

    setGlobalOptions = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Rendered as `set -g <name> <value>`.";
    };

    setWindowOptions = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Rendered as `set-window-option -g <name> <value>`.";
    };

    setServerOptions = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Rendered as `set -sg <name> <value>`.";
    };

    enableVimIntegration = lib.mkEnableOption "vim-aware C-hjkl pane nav (root + copy-mode-vi + C-\\ last-pane)";

    bindings = lib.mkOption {
      type = lib.types.attrsOf bindingType;
      default = { };
      description = "Named key bindings; attr name describes the binding.";
    };

    keyTables = lib.mkOption {
      type = lib.types.attrsOf (lib.types.attrsOf keyTableBindingType);
      default = { };
      description = "Named custom key tables containing key bindings.";
    };

    hooks = lib.mkOption {
      type = lib.types.attrsOf hookType;
      default = { };
      description = "Named set-hook entries.";
    };

    unbind = lib.mkOption {
      type = lib.types.listOf unbindType;
      default = [ ];
      description = "unbind-key entries.";
    };

    extraConfig = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = "Verbatim lines appended after generated config.";
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ cfg.package ];
    home.file.".tmux.conf".text = configText + "\n";
  };
}
