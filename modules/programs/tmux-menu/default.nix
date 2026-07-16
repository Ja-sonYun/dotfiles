{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.tmux-menu;
  yamlFormat = pkgs.formats.yaml { };

  posType = lib.types.submodule {
    options = {
      x = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
      };
      y = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
      };
      w = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
      };
      h = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
      };
    };
  };

  menuEntryType = lib.types.submodule {
    options = {
      name = lib.mkOption { type = lib.types.str; };
      shortcut = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
      };
      command = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
      };
      nextMenu = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Target menu by attr name (e.g. \"git\"); \".yaml\" is appended.";
      };
      closeAfterCommand = lib.mkOption {
        type = lib.types.nullOr lib.types.bool;
        default = null;
      };
      session = lib.mkOption {
        type = lib.types.bool;
        default = false;
      };
      sessionName = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
      };
      keyTable = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
      };
      sessionOnDir = lib.mkOption {
        type = lib.types.bool;
        default = false;
      };
      runOnGitRoot = lib.mkOption {
        type = lib.types.bool;
        default = false;
      };
      background = lib.mkOption {
        type = lib.types.bool;
        default = false;
      };
      inputs = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
      };
      position = lib.mkOption {
        type = lib.types.nullOr posType;
        default = null;
      };
      border = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
      };
      environment = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
      };
    };
  };

  itemType = lib.types.submodule {
    options = {
      separator = lib.mkOption {
        type = lib.types.bool;
        default = false;
      };
      noDim = lib.mkOption {
        type = lib.types.nullOr (
          lib.types.submodule { options.name = lib.mkOption { type = lib.types.str; }; }
        );
        default = null;
      };
      menu = lib.mkOption {
        type = lib.types.nullOr menuEntryType;
        default = null;
      };
    };
  };

  menuType = lib.types.submodule {
    options = {
      title = lib.mkOption { type = lib.types.str; };
      border = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
      };
      position = lib.mkOption {
        type = lib.types.nullOr posType;
        default = null;
      };
      items = lib.mkOption {
        type = lib.types.listOf itemType;
        default = [ ];
      };
    };
  };

  renderPos =
    p:
    lib.filterAttrs (_: v: v != null) {
      inherit (p)
        x
        y
        w
        h
        ;
    };

  renderMenuEntry =
    e:
    {
      inherit (e) name;
    }
    // lib.optionalAttrs (e.shortcut != null) { inherit (e) shortcut; }
    // lib.optionalAttrs (e.command != null) { inherit (e) command; }
    // lib.optionalAttrs (e.nextMenu != null) { next_menu = "${e.nextMenu}.yaml"; }
    // lib.optionalAttrs (e.closeAfterCommand != null) { close_after_command = e.closeAfterCommand; }
    // lib.optionalAttrs e.session { session = true; }
    // lib.optionalAttrs (e.sessionName != null) { session_name = e.sessionName; }
    // lib.optionalAttrs (e.keyTable != null) { key_table = e.keyTable; }
    // lib.optionalAttrs e.sessionOnDir { session_on_dir = true; }
    // lib.optionalAttrs e.runOnGitRoot { run_on_git_root = true; }
    // lib.optionalAttrs e.background { background = true; }
    // lib.optionalAttrs (e.inputs != [ ]) { inherit (e) inputs; }
    // lib.optionalAttrs (e.position != null) { position = renderPos e.position; }
    // lib.optionalAttrs (e.border != null) { inherit (e) border; }
    // lib.optionalAttrs (e.environment != { }) { inherit (e) environment; };

  renderItem =
    item:
    if item.menu != null then
      { Menu = renderMenuEntry item.menu; }
    else if item.noDim != null then
      { NoDim = { inherit (item.noDim) name; }; }
    else
      { Seperate = { }; };

  renderMenu =
    m:
    {
      inherit (m) title;
      items = map renderItem m.items;
    }
    // lib.optionalAttrs (m.border != null) { inherit (m) border; }
    // lib.optionalAttrs (m.position != null) { position = renderPos m.position; };

  generatedMenus = lib.mapAttrs (
    name: m: yamlFormat.generate "${name}.yaml" (renderMenu m)
  ) cfg.menus;
in
{
  options.programs.tmux-menu = {
    enable = lib.mkEnableOption "tmux-menu";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.tmux-menu;
      description = "tmux-menu package to install.";
    };

    menus = lib.mkOption {
      type = lib.types.attrsOf menuType;
      default = { };
      description = "Menus rendered to YAML; attr name is the file stem (e.g. menu, git).";
    };

    configDir = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      internal = true;
      description = "Dir containing generated menu YAMLs under menu/.";
    };

    showScript = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      internal = true;
      description = "Launcher that shows the @menu (or 'menu') group.";
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ cfg.package ];

    programs.tmux-menu.showScript = pkgs.writeShellScript "tmux-menu-show" ''
      IFS=$'\x1f' read -r pane_current_path pane_id window_id < <(
        tmux display-message -p $'#{pane_current_path}\x1f#{pane_id}\x1f#{window_id}'
      )
      tmux set-option -g @menu_origin_pane "$pane_id" ';' set-option -g @menu_origin_window "$window_id"
      menu=$(tmux show -v @menu 2>/dev/null)
      menu=''${menu:-menu}
      if tmux show-environment DEFAULT >/dev/null 2>&1; then
        ${cfg.package}/bin/tmux-menu show --menu ${cfg.configDir}/menu/"$menu".yaml --working_dir "$pane_current_path"
      else
        tmux detach
        W=$(tmux display -p "#{client_width}"); W=$((W - 1))
        H=$(tmux display -p "#{client_height}")
        ${cfg.package}/bin/tmux-menu show -x "$W" -y "$H" --menu ${cfg.configDir}/menu/"$menu".yaml --working_dir "$pane_current_path"
      fi
    '';

    programs.tmux-menu.configDir = pkgs.runCommand "tmux-config" { } (
      ''
        mkdir -p $out/menu
      ''
      + lib.concatStrings (
        lib.mapAttrsToList (name: file: "cp ${file} $out/menu/${name}.yaml\n") generatedMenus
      )
    );
  };
}
