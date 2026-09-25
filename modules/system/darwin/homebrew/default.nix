{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.homebrew;
  applyFormulaLinks = pkgs.writeShellScript "apply-homebrew-formula-links" ''
    set -euo pipefail

    brew=${lib.escapeShellArg "${cfg.prefix}/bin/brew"}
    if [ ! -x "$brew" ]; then
      echo "Homebrew executable not found: $brew" >&2
      exit 1
    fi

    installed=$(/usr/bin/sudo --user=${lib.escapeShellArg cfg.user} --set-home \
      /usr/bin/env HOMEBREW_NO_AUTO_UPDATE=1 "$brew" list --formula --full-name)

    ${lib.concatStringsSep "\n" (
      lib.mapAttrsToList (formula: linked: ''
        if /usr/bin/grep -Fxq -- ${lib.escapeShellArg formula} <<< "$installed"; then
          /usr/bin/sudo --user=${lib.escapeShellArg cfg.user} --set-home \
            /usr/bin/env HOMEBREW_NO_AUTO_UPDATE=1 "$brew" ${
              if linked then "link --formula --force" else "unlink --formula"
            } ${lib.escapeShellArg formula}

          if ! /usr/bin/sudo --user=${lib.escapeShellArg cfg.user} --set-home \
            /usr/bin/env HOMEBREW_NO_AUTO_UPDATE=1 "$brew" info --json=v2 --formula \
            ${lib.escapeShellArg formula} | ${pkgs.jq}/bin/jq -e '
              (.formulae | length == 1) and
              (.formulae[0] | has("linked_keg")) and
              (.formulae[0].linked_keg | ${
                if linked then ''type == "string" and length > 0'' else ". == null"
              })
            ' > /dev/null; then
            echo ${lib.escapeShellArg "Homebrew formula ${formula}: could not confirm ${if linked then "linked" else "unlinked"} state"} >&2
            exit 1
          fi
        fi
      '') cfg.formulaLinks
    )}
  '';
in
{
  options.homebrew.formulaLinks = lib.mkOption {
    type = lib.types.attrsOf lib.types.bool;
    default = { };
    example = {
      node = false;
    };
    description = "Link (true) or unlink (false) installed formulae.";
  };

  config = lib.mkIf (cfg.enable && cfg.formulaLinks != { }) {
    system.activationScripts.postActivation.text = lib.mkAfter ''
      ${applyFormulaLinks} || exit $?
    '';
  };
}
