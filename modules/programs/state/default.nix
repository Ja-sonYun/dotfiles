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
  statePython = pkgs.python3.withPackages (packages: [ packages.tomlkit ]);
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
                description = "Dotted state key for executable selection.";
              };

              default = lib.mkOption {
                type = lib.types.enum (builtins.attrNames config.choices);
                description = "Executable selection written during activation when the state key is missing.";
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
      description = "Commands selected by runtime state.";
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ pkgs.state-get ] ++ commandPackages;

    home.activation.initializeState = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      if [[ ! -e ${lib.escapeShellArg stateFile} && ! -L ${lib.escapeShellArg stateFile} ]]; then
        run ${pkgs.coreutils}/bin/install -m 600 ${initialState} ${lib.escapeShellArg stateFile}
      else
        run ${statePython}/bin/python3 -c ${lib.escapeShellArg ''
          import os
          import stat
          import sys
          import tempfile
          from collections.abc import Mapping, MutableMapping
          from pathlib import Path

          import tomlkit


          def add_missing(state: MutableMapping[str, object], defaults: Mapping[str, object]) -> bool:
              changed = False
              for key, value in defaults.items():
                  if key not in state:
                      state[key] = value
                      changed = True
                  elif isinstance(value, Mapping):
                      current = state[key]
                      if not isinstance(current, MutableMapping):
                          raise ValueError(f"State key {key!r} must be a table")
                      changed = add_missing(current, value) or changed
              return changed


          state_path = Path(sys.argv[2]).resolve(strict=True)
          defaults = tomlkit.parse(Path(sys.argv[1]).read_text(encoding="utf-8"))
          state = tomlkit.parse(state_path.read_text(encoding="utf-8"))

          if add_missing(state, defaults):
              content = tomlkit.dumps(state)
              mode = stat.S_IMODE(state_path.stat().st_mode)
              descriptor, temporary_name = tempfile.mkstemp(prefix=".state-", dir=state_path.parent)
              temporary_path = Path(temporary_name)
              try:
                  with os.fdopen(descriptor, "w", encoding="utf-8") as output:
                      os.fchmod(output.fileno(), mode)
                      output.write(content)
                      output.flush()
                      os.fsync(output.fileno())
                  temporary_path.replace(state_path)
              finally:
                  temporary_path.unlink(missing_ok=True)
        ''} ${initialState} ${lib.escapeShellArg stateFile}
      fi
    '';
  };
}
