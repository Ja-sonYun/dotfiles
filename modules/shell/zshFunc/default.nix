{
  config,
  pkgs,
  lib,
  ...
}:
with lib;

let
  cfg = config.programs.zshFunc;
in
{
  options.programs.zshFunc = mkOption {
    type =
      with types;
      attrsOf (submodule {
        options = {
          description = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Help text. When null, no -h/--help parsing is added.";
          };
          command = mkOption {
            type = types.str;
            default = "echo 'No command provided.'";
          };
          source = mkOption {
            type = types.bool;
            default = false;
            description = "If true, define as a zsh function in initContent.";
          };
        };
      });
    default = { };
    description = "Zsh functions with optional help and sourceable functions.";
  };

  config =
    let
      toScriptBin =
        name: fn:
        let
          hasDesc = fn ? description && fn.description != null;
          helpBlock = optionalString hasDesc ''
            if [[ "''${1-}" == "-h" || "''${1-}" == "--help" ]]; then
              print -- "${fn.description}"
              exit 0
            fi
          '';
        in
        pkgs.writeScriptBin name ''
          #!${pkgs.zsh}/bin/zsh
          set -euo pipefail
          ${helpBlock}
          ${fn.command}
        '';

      binAttrs = filterAttrs (_: fn: !(fn.source or false)) cfg;
      allBins = mapAttrsToList toScriptBin binAttrs;

      sourcedFns = concatStringsSep "\n\n" (
        mapAttrsToList (
          name: fn:
          let
            hasDesc = fn ? description && fn.description != null;
            helpBlock = optionalString hasDesc ''
              if [[ "''${1-}" == "-h" || "''${1-}" == "--help" ]]; then
                print -- "${fn.description}"
                return 0
              fi
            '';
          in
          ''
            # ${optionalString hasDesc fn.description}
            ${name}() {
              ${helpBlock}
              ${fn.command}
            }
          ''
        ) (filterAttrs (_: fn: fn.source or false) cfg)
      );
    in
    {
      home.packages = allBins;
      programs.zsh.initContent = lib.mkAfter sourcedFns;
    };
}
