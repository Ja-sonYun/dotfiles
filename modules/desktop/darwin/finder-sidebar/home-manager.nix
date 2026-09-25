{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.finderSidebar;
  absolutePath = lib.types.addCheck lib.types.nonEmptyStr (lib.hasPrefix "/");
  itemName = lib.types.addCheck lib.types.nonEmptyStr (
    name: !(lib.hasInfix "\n" name || lib.hasInfix "\r" name || lib.hasInfix " -> " name)
  );
  names = map (item: item.name) (cfg.items ++ cfg.hiddenItems);
  settings = pkgs.writeText "finder-sidebar.json" (
    builtins.toJSON {
      inherit (cfg)
        enable
        items
        hiddenItems
        monthlyFolders
        ;
      mysides = "${pkgs.mysides}/bin/mysides";
      stateDirectory = "${config.xdg.stateHome}/finder-sidebar";
    }
  );
  sidebar = pkgs.writeShellScript "finder-sidebar" ''
    exec ${pkgs.python3}/bin/python3 ${./finder-sidebar.py} ${settings}
  '';
in
{
  options.services.finderSidebar = {
    enable = lib.mkOption {
      type = lib.types.nullOr lib.types.bool;
      default = null;
      description = "Manage sidebar items; null leaves them unmanaged.";
    };
    items = lib.mkOption {
      default = [ ];
      description = "Ordered sidebar folders; retained when disabled.";
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            name = lib.mkOption { type = itemName; };
            path = lib.mkOption { type = absolutePath; };
          };
        }
      );
    };
    hiddenItems = lib.mkOption {
      default = [ ];
      description = "Items to hide; restored when disabled.";
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            name = lib.mkOption { type = itemName; };
            uri = lib.mkOption { type = lib.types.nonEmptyStr; };
          };
        }
      );
    };
    monthlyFolders = lib.mkOption {
      default = null;
      description = "Current and previous month folders after a named item.";
      type = lib.types.nullOr (
        lib.types.submodule {
          options = {
            path = lib.mkOption { type = absolutePath; };
            after = lib.mkOption { type = itemName; };
          };
        }
      );
    };
  };

  config = lib.mkIf (cfg.enable != null) (
    lib.mkMerge [
      {
        assertions = [
          {
            assertion = builtins.length names == builtins.length (lib.unique names);
            message = "finderSidebar items and hiddenItems must have unique names.";
          }
          {
            assertion =
              cfg.monthlyFolders == null || lib.any (item: item.name == cfg.monthlyFolders.after) cfg.items;
            message = "finderSidebar.monthlyFolders.after must name an item in finderSidebar.items.";
          }
        ];
        launchd.agents.finder-sidebar = {
          inherit (cfg) enable;
          config = {
            Label = "com.user.finder-sidebar";
            ProgramArguments = [ "${sidebar}" ];
            LimitLoadToSessionType = "Aqua";
            RunAtLoad = true;
            StartCalendarInterval = [
              {
                Hour = 0;
                Minute = 5;
              }
            ];
            StandardOutPath = "/tmp/finder-sidebar.log";
            StandardErrorPath = "/tmp/finder-sidebar.log";
          };
        };
      }
      (lib.mkIf (!cfg.enable) {
        home.activation.cleanupFinderSidebar = lib.hm.dag.entryAfter [ "setupLaunchAgents" ] ''
          run ${sidebar}
        '';
      })
    ]
  );
}
