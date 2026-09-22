{
  config,
  lib,
  pkgs,
  username,
  ...
}:
let
  cfg = config.services.hammerspoon;
  scriptsDir = pkgs.linkFarm "hammerspoon-scripts" (
    [
      {
        name = "logging.lua";
        path = ./logging.lua;
      }
    ]
    ++ cfg.scripts
  );
  scriptRequires = lib.concatMapStringsSep "\n" (
    script: ''loadModule("${lib.removeSuffix ".lua" script.name}")''
  ) cfg.scripts;
  initLua = pkgs.replaceVars ./init.lua {
    autoLaunch = lib.boolToString cfg.autoLaunch;
    inherit scriptRequires scriptsDir;
  };
in
{
  options.services.hammerspoon = {
    enable = lib.mkEnableOption "Hammerspoon";

    autoLaunch = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether Hammerspoon starts automatically at login.";
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
      description = "Named Hammerspoon Lua modules loaded in list order.";
    };
  };

  config = lib.mkIf cfg.enable {
    homebrew.casks = [ "hammerspoon" ];

    home-manager.users.${username}.home.file.".hammerspoon/init.lua".source = initLua;
  };
}
