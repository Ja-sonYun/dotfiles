{
  config,
  lib,
  pkgs,
  username,
  ...
}:
let
  cfg = config.services.hammerspoon;
  logging = config.home-manager.users.${username}.programs.logging;
  hasKeybindings = cfg.keybindings != { };
  keybindingsFile = pkgs.writeText "hammerspoon-keybindings.json" (
    builtins.toJSON (
      lib.mapAttrsToList (
        name: binding:
        let
          parts = lib.splitString "-" name;
        in
        lib.filterAttrs (_: value: value != null) (
          binding
          // {
            inherit name;
            key = lib.last parts;
            modifiers = lib.init parts;
          }
        )
      ) cfg.keybindings
    )
  );
  scriptsDir = pkgs.linkFarm "hammerspoon-scripts" (
    [
      {
        name = "logging.lua";
        path = pkgs.replaceVars ./logging.lua {
          configJson = builtins.toJSON {
            socketPath = if logging.enable then logging.socketPath else "";
            inherit (logging) level;
          };
        };
      }
    ]
    ++ cfg.scripts
  );
  scriptRequires = lib.concatMapStringsSep "\n" (
    script: ''loadModule("${lib.removeSuffix ".lua" script.name}")''
  ) cfg.scripts;
  initLua = pkgs.replaceVars ./init.lua {
    autoLaunch = lib.boolToString cfg.autoLaunch;
    windowFilterLoader = ./window-filter.lua;
    inherit scriptRequires scriptsDir;
  };
in
{
  options.services.hammerspoon = {
    enable = lib.mkEnableOption "Hammerspoon";

    autoLaunch = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Start at login.";
    };

    keybindings = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            command = lib.mkOption {
              type = lib.types.nullOr (
                lib.types.oneOf [
                  lib.types.nonEmptyStr
                  (lib.types.addCheck (lib.types.nonEmptyListOf lib.types.str) (
                    command: lib.hasPrefix "/" (lib.head command)
                  ))
                ]
              );
              default = null;
              description = ''
                Shell command string run asynchronously with Nix Bash, or an argv
                list run directly without a shell. The first list item must be an
                absolute executable path. Mutually exclusive with lua, sendKey, and socket.
              '';
            };
            lua = lib.mkOption {
              type = lib.types.nullOr lib.types.nonEmptyStr;
              default = null;
              description = ''
                Lua code run synchronously inside Hammerspoon.
                Mutually exclusive with command, sendKey, and socket.
              '';
            };
            sendKey = lib.mkOption {
              type = lib.types.nullOr (
                lib.types.submodule {
                  options = {
                    modifiers = lib.mkOption {
                      type = lib.types.listOf (
                        lib.types.enum [
                          "cmd"
                          "alt"
                          "ctrl"
                          "shift"
                        ]
                      );
                      default = [ ];
                      description = "Modifiers for the synthesized keystroke.";
                    };
                    key = lib.mkOption {
                      type = lib.types.nonEmptyStr;
                      description = "Hammerspoon key name or hexadecimal physical key code.";
                    };
                  };
                }
              );
              default = null;
              description = "Keystroke to synthesize. Mutually exclusive with command, lua, and socket.";
            };
            socket = lib.mkOption {
              type = lib.types.nullOr (
                lib.types.submodule {
                  options = {
                    path = lib.mkOption {
                      type = lib.types.addCheck lib.types.nonEmptyStr (lib.hasPrefix "/");
                      description = "Absolute Unix stream socket path.";
                    };
                    payload = lib.mkOption {
                      type = lib.types.attrsOf (pkgs.formats.json { }).type;
                      description = "JSON object sent as the request payload.";
                    };
                  };
                }
              );
              default = null;
              description = ''
                Asynchronous socket action, mutually exclusive with command, lua, and sendKey.
                Sends one JSON line containing id and payload. The server must reply
                within 15 seconds with a JSON line containing the same id, boolean ok,
                and an optional error string. Requests to each path run in order.
                Failed connections discard pending requests without replaying them.
              '';
            };
            passthrough = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Also deliver the original key events to the focused application.";
            };
          };
        }
      );
      default = { };
      description = ''
        Global key bindings named modifier-key, using cmd, rcmd, alt, lalt, ctrl,
        and shift. Keys use Hammerspoon names or hexadecimal physical codes.
        Key-down repetition is preserved. Requires Hammerspoon to be enabled.
      '';
    };

    scripts = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            name = lib.mkOption {
              type = lib.types.nonEmptyStr;
            };
            path = lib.mkOption {
              type = lib.types.oneOf [
                lib.types.package
                lib.types.path
              ];
            };
          };
        }
      );
      default = [ ];
      description = "Lua modules in load order.";
    };
  };

  config = lib.mkMerge [
    (lib.mkIf hasKeybindings {
      assertions = [
        {
          assertion = cfg.enable;
          message = "services.hammerspoon.keybindings requires services.hammerspoon.enable.";
        }
        {
          assertion = lib.all (
            binding:
            builtins.length (
              lib.filter (value: value != null) [
                binding.command
                binding.lua
                binding.sendKey
                binding.socket
              ]
            ) == 1
          ) (builtins.attrValues cfg.keybindings);
          message = "Each Hammerspoon keybinding must set exactly one of command, lua, sendKey, or socket.";
        }
        {
          assertion = lib.all (
            name:
            let
              parts = lib.splitString "-" name;
            in
            lib.last parts != ""
            && lib.all (
              modifier:
              lib.elem modifier [
                "cmd"
                "rcmd"
                "alt"
                "lalt"
                "ctrl"
                "shift"
              ]
            ) (lib.init parts)
          ) (builtins.attrNames cfg.keybindings);
          message = "Hammerspoon keybinding names must contain a key and supported modifiers.";
        }
      ];

      services.hammerspoon.scripts = [
        {
          name = "keybindings.lua";
          path = pkgs.replaceVars ./keybindings.lua {
            bindings = keybindingsFile;
            bash = "${pkgs.bash}/bin/bash";
          };
        }
      ];
    })
    (lib.mkIf cfg.enable {
      homebrew.casks = [ "hammerspoon" ];

      home-manager.users.${username}.home.file.".hammerspoon/init.lua".source = initLua;
    })
  ];
}
