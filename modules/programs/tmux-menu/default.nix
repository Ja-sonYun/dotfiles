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
      runOnRoot = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
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
    // lib.optionalAttrs (e.runOnRoot != null) { run_on_root = e.runOnRoot; }
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
      pane_id="$1"
      window_id="$2"
      client_name="$3"
      pane_current_path="$4"
      if [ -z "$pane_id" ] || [ -z "$window_id" ] || [ -z "$client_name" ]; then
        exit 0
      fi
      if [ -z "$pane_current_path" ]; then
        pane_current_path=$(tmux display-message -pt "$pane_id" '#{pane_current_path}' 2>/dev/null) || exit 0
        [ -n "$pane_current_path" ] || exit 0
      fi
      export TMUX_MENU_ORIGIN_PANE="$pane_id"
      export TMUX_MENU_ORIGIN_WINDOW="$window_id"
      export TMUX_MENU_CLIENT="$client_name"
      menu=$(tmux show-options -qv @menu)
      menu=''${menu:-menu}
      if [ -n "$(tmux display-message -pt "$pane_id" '#{E:DEFAULT}')" ]; then
        exec ${cfg.package}/bin/tmux-menu show --menu ${cfg.configDir}/menu/"$menu".yaml --working_dir "$pane_current_path"
      fi

      session=$(tmux display-message -pt "$pane_id" '#{session_name}' 2>/dev/null)
      key="''${session//[^A-Za-z0-9]/_}"
      outer=$(tmux show-options -gqv "@popup_client_$key" 2>/dev/null)
      W="" H=""
      if [ -n "$outer" ] && [ "$outer" != "$client_name" ]; then
        read -r W H < <(tmux list-clients -F $'#{client_name}\t#{client_width} #{client_height}' 2>/dev/null |
          awk -F '\t' -v c="$outer" '$1 == c { print $2; exit }')
      fi
      tmux detach-client -t "$client_name" 2>/dev/null
      if [ -n "$W" ] && [ -n "$H" ]; then
        export TMUX_MENU_CLIENT="$outer"
        exec ${cfg.package}/bin/tmux-menu show -x "$((W - 1))" -y "$H" --menu ${cfg.configDir}/menu/"$menu".yaml --working_dir "$pane_current_path"
      fi
      unset TMUX_MENU_CLIENT
      exec ${cfg.package}/bin/tmux-menu show --menu ${cfg.configDir}/menu/"$menu".yaml --working_dir "$pane_current_path"
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
