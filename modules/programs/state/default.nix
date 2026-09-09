{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.state;
  tomlFormat = pkgs.formats.toml { };
  initialSettings = lib.foldl' lib.recursiveUpdate { } (
    lib.mapAttrsToList (
      _: command: lib.setAttrByPath (lib.splitString "." command.key) command.default
    ) cfg.commands
  );
  initialState = tomlFormat.generate "initial-state.toml" initialSettings;
  stateFile = "${config.home.homeDirectory}/.state.toml";
  commandPackages = lib.mapAttrsToList (
    name: command:
    let
      choices = pkgs.writeText "${name}-state-choices.json" (builtins.toJSON command.choices);
    in
    pkgs.writeShellScriptBin name ''
      exec ${pkgs.state-get}/bin/state-exec ${lib.escapeShellArg command.key} ${choices} "$@"
    ''
  ) cfg.commands;
in
{
  options.programs.state = {
    enable = lib.mkEnableOption "runtime state" // {
      default = cfg.commands != { };
    };

    commands = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule (
          { config, ... }:
          {
            options = {
              key = lib.mkOption {
                type = lib.types.strMatching "[A-Za-z_][A-Za-z0-9_-]*(\\.[A-Za-z_][A-Za-z0-9_-]*)*";
                description = "Dotted state key selecting the executable.";
              };

              default = lib.mkOption {
                type = lib.types.enum (builtins.attrNames config.choices);
                description = "Initial selection when ~/.state.toml is first created.";
              };

              choices = lib.mkOption {
                type = lib.types.attrsOf lib.types.str;
                description = "State values mapped to executable paths.";
              };
            };
          }
        )
      );
      default = { };
      description = "Commands that select an executable from runtime state.";
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ pkgs.state-get ] ++ commandPackages;

    home.activation.initializeState = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      if [[ ! -e ${lib.escapeShellArg stateFile} && ! -L ${lib.escapeShellArg stateFile} ]]; then
        run ${pkgs.coreutils}/bin/install -m 600 ${initialState} ${lib.escapeShellArg stateFile}
      fi
    '';
  };
}
