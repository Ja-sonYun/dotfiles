{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.tmux;

  bindingType = lib.types.submodule (
    { name, ... }:
    {
      options = {
        key = lib.mkOption {
          type = lib.types.str;
          default = name;
          description = "Key spec emitted verbatim to bind-key; defaults to the attribute name.";
        };
        table = lib.mkOption {
          type = lib.types.enum [
            "prefix"
            "root"
            "copy-mode-vi"
          ];
          default = "prefix";
          description = "Key table: root -> -n, others -> -T <table>.";
        };
        repeat = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Add -r (repeatable).";
        };
        command = lib.mkOption {
          type = lib.types.str;
          description = "tmux command(s); use \\; to chain.";
        };
      };
    }
  );

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

  renderBinding =
    _name: b:
    lib.concatStringsSep " " (
      [
        "bind-key"
        (tableFlag b.table)
      ]
      ++ lib.optional b.repeat "-r"
      ++ [
        b.key
        b.command
      ]
    );

  renderUnbind = u: "unbind-key ${lib.optionalString (u.table != null) "-T ${u.table} "}${u.key}";

  renderHook = _name: h: "set-hook -g ${h.event} '${h.command}'";

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
      (lib.mapAttrsToList renderHook cfg.hooks)
      (map renderUnbind cfg.unbind)
      (lib.mapAttrsToList renderBinding cfg.bindings)
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
