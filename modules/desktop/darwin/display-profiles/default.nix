{
  config,
  lib,
  pkgs,
  username,
  ...
}:
let
  cfg = config.services.displayProfiles;
  displayLayoutsJson = pkgs.writeText "display-layouts.json" (builtins.toJSON cfg.layouts);
  applyDisplayProfile = pkgs.writeShellApplication {
    name = "apply-display-profile";
    runtimeInputs = [
      pkgs.gawk
      pkgs.jq
    ];
    text = ''
      export APPLY_DISPLAY_PROFILE_CONFIG="${displayLayoutsJson}"
      displayplacer_bin=${lib.escapeShellArg "${config.homebrew.prefix}/bin/displayplacer"}
      ${builtins.readFile ./apply-display-profile.sh}
    '';
  };
  optionalString = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
  };
in
{
  options.services.displayProfiles = {
    enable = lib.mkEnableOption "display layout profiles";
    layouts = lib.mkOption {
      description = "Layouts in preference order; the first matching layout is applied.";
      default = [ ];
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            name = lib.mkOption {
              type = lib.types.str;
            };
            displays = lib.mkOption {
              type = lib.types.listOf (
                lib.types.submodule {
                  options = {
                    name = lib.mkOption {
                      type = lib.types.str;
                    };
                    resolution = lib.mkOption {
                      type = lib.types.str;
                    };
                    scaling = lib.mkOption {
                      type = lib.types.str;
                      default = "on";
                    };
                    matchType = optionalString;
                    matchId = optionalString;
                    matchName = optionalString;
                    matchSerial = optionalString;
                    origin = optionalString;
                    matchIndex = lib.mkOption {
                      type = lib.types.nullOr lib.types.ints.positive;
                      default = null;
                    };
                    degree = lib.mkOption {
                      type = lib.types.nullOr lib.types.int;
                      default = null;
                    };
                  };
                }
              );
            };
          };
        }
      );
    };
  };
  config = lib.mkIf cfg.enable {
    homebrew.brews = [ "displayplacer" ];
    environment.systemPackages = [ applyDisplayProfile ];
    system.activationScripts.postActivation.text = lib.mkAfter ''
      uid="$(/usr/bin/id -u ${lib.escapeShellArg username})"
      if /bin/launchctl print "gui/$uid" >/dev/null 2>&1; then
        /bin/launchctl asuser "$uid" \
          /usr/bin/sudo --user ${lib.escapeShellArg username} -- \
          "${applyDisplayProfile}/bin/apply-display-profile" || true
      fi
    '';
  };
}
