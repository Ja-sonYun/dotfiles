{
  config,
  lib,
  pkgs,
  userhome,
  ...
}:
let
  cfg = config.services.fileOrganizer;
  absolutePath = lib.types.addCheck lib.types.nonEmptyStr (lib.hasPrefix "/");
  tagName =
    name: name != "" && !(lib.hasInfix "," name || lib.hasInfix "\n" name || lib.hasInfix "\r" name);
  jev = pkgs.writeShellScript "file-organizer-jev" ''
    set -e
    ${pkgs.tool.shell.util.shellExports {
      TYPESAFE_API_KEY._secret = cfg.apiKeyFile;
    }}
    if [ -z "$TYPESAFE_API_KEY" ]; then
      echo "File organizer API key file is missing, unreadable, or empty." >&2
      exit 1
    fi

    exec ${pkgs.jev}/bin/jev "$@"
  '';
  settings = pkgs.writeText "file-organizer.json" (
    builtins.toJSON {
      inherit (cfg)
        policies
        tags
        extensions
        model
        ;
      stateDirectory = "${userhome}/.local/state/file-organizer";
      jev = "${jev}";
      pdftotext = "${pkgs.poppler-utils}/bin/pdftotext";
      refresh = cfg.onMonthlyFoldersReady;
    }
  );
  runner = pkgs.writeShellScript "file-organizer" ''
    exec ${pkgs.python3}/bin/python3 ${./organizer.py} ${settings} "$@"
  '';
  script = pkgs.replaceVars ./watch.lua {
    command = runner;
    paths = builtins.toJSON (map (p: p.source) cfg.policies);
  };
in
{
  options.services.fileOrganizer = {
    enable = lib.mkEnableOption "file tagging and monthly organization" // {
      description = "Register the file-organizer Hammerspoon module. When false, existing files, tags, folders and processing records are not removed.";
    };
    apiKeyFile = lib.mkOption {
      type = lib.types.str;
      default = "";
    };
    model = lib.mkOption {
      type = lib.types.str;
      default = "jev-latest";
    };
    onMonthlyFoldersReady = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Executable invoked after preparing current and previous month folders.";
    };
    tags = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
    };
    extensions = lib.mkOption {
      type = lib.types.attrsOf (lib.types.listOf lib.types.str);
      default = { };
    };
    policies = lib.mkOption {
      default = [ ];
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            source = lib.mkOption { type = absolutePath; };
            destination = lib.mkOption { type = absolutePath; };
            monthFormat = lib.mkOption {
              type = lib.types.enum [
                "%Y.%m"
                "%Y-%m"
                "%Y_%m"
              ];
              default = "%Y.%m";
            };
            maxFileSize = lib.mkOption {
              type = lib.types.ints.positive;
              default = 1000000000;
              description = "Maximum size in bytes eligible for AI classification and monthly movement.";
            };
          };
        }
      );
    };
  };
  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.policies != [ ] && cfg.tags != { };
        message = "fileOrganizer requires at least one folder policy and one classification tag.";
      }
      {
        assertion = lib.all tagName (
          builtins.attrNames cfg.tags ++ lib.concatLists (builtins.attrValues cfg.extensions)
        );
        message = "fileOrganizer tag names must be nonempty and contain no commas or newlines.";
      }
      {
        assertion =
          builtins.length cfg.policies
          == builtins.length (lib.unique (map (policy: policy.source) cfg.policies));
        message = "fileOrganizer source directories must be unique.";
      }
      {
        assertion = config.services.hammerspoon.enable;
        message = "fileOrganizer requires Hammerspoon.";
      }
      {
        assertion = cfg.apiKeyFile != "";
        message = "fileOrganizer requires apiKeyFile.";
      }
    ];
    services.hammerspoon.scripts = [
      {
        name = "file-organizer.lua";
        path = script;
      }
    ];
  };
}
