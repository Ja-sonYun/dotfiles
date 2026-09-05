{
  config,
  lib,
  pkgs,
  username,
  ...
}:
let
  cfg = config.services.hammerspoon;
  customScripts = map (script: {
    name = builtins.baseNameOf script;
    path = script;
  }) cfg.scripts;
  scripts = cfg.preparedScripts ++ customScripts;
  scriptsDir = pkgs.linkFarm "hammerspoon-scripts" (
    map (script: {
      inherit (script) name path;
    }) scripts
  );
  scriptRequires = lib.concatMapStringsSep "\n" (
    script: ''require("${lib.removeSuffix ".lua" script.name}")''
  ) scripts;
  initLua = pkgs.replaceVars ./init.lua {
    autoLaunch = lib.boolToString cfg.autoLaunch;
    inherit scriptRequires scriptsDir;
  };
in
{
  imports = [
    ./scripts/mute-microphone-on-lock/module.nix
    ./scripts/application-input-sources/module.nix
    ./scripts/meeting-recorder/module.nix
  ];

  options.services.hammerspoon = {
    enable = lib.mkEnableOption "Hammerspoon";

    autoLaunch = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether Hammerspoon starts automatically at login.";
    };

    scripts = lib.mkOption {
      type = lib.types.listOf lib.types.path;
      default = [ ];
      description = "Hammerspoon Lua modules loaded in list order.";
    };

    preparedScripts = lib.mkOption {
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
      description = "Prepared Hammerspoon Lua modules.";
      visible = false;
    };
  };

  config = lib.mkIf cfg.enable {
    homebrew.casks = [ "hammerspoon" ];

    home-manager.users.${username}.home.file.".hammerspoon/init.lua".source = initLua;
  };
}
