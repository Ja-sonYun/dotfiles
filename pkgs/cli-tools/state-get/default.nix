{ pkgs, ... }:

let
  get = pkgs.writeShellScriptBin "state-get" ''
    set -euo pipefail

    if [[ $# -ne 1 || ! "$1" =~ ^[A-Za-z_][A-Za-z0-9_-]*(\.[A-Za-z_][A-Za-z0-9_-]*)*$ ]]; then
      echo "Usage: state-get <dotted-key>" >&2
      exit 1
    fi

    state_file="$HOME/.state.toml"
    value_type=$(${pkgs.yq-go}/bin/yq --input-format=toml --output-format=yaml --unwrapScalar ".$1 | tag" "$state_file")
    if [[ "$value_type" == '!!null' ]]; then
      echo "state-get: missing key '$1' in $state_file" >&2
      exit 1
    fi

    exec ${pkgs.yq-go}/bin/yq --input-format=toml --output-format=yaml --unwrapScalar ".$1" "$state_file"
  '';

  run = pkgs.writeShellScriptBin "state-run" ''
    set -euo pipefail

    if [[ $# -lt 2 ]]; then
      echo "Usage: state-run <name> <executable> [args...]" >&2
      exit 1
    fi

    export STATE_COMMAND_NAME="$1"
    command="$2"
    shift 2
    if [[ -n "''${STATE_COMMAND_NOTIFY:-}" ]]; then
      "$STATE_COMMAND_NOTIFY" || :
    fi
    exec "$command" "$@"
  '';

  execute = pkgs.writeShellScriptBin "state-exec" ''
    set -euo pipefail

    if [[ $# -lt 2 ]]; then
      echo "Usage: state-exec <dotted-key> <choices.json> [args...]" >&2
      exit 1
    fi

    key="$1"
    choices="$2"
    shift 2
    STATE_VALUE=$(${get}/bin/state-get "$key")
    export STATE_VALUE
    if ! command=$(${pkgs.yq-go}/bin/yq --input-format=json --output-format=yaml --unwrapScalar --exit-status \
      '.[strenv(STATE_VALUE)] | select(tag == "!!str")' "$choices"); then
      echo "state-exec: no executable for '$key' value '$STATE_VALUE'" >&2
      exit 1
    fi
    selection="$STATE_VALUE"
    unset STATE_VALUE
    exec ${run}/bin/state-run "$selection" "$command" "$@"
  '';
in
pkgs.symlinkJoin {
  name = "state-utils";
  paths = [
    get
    run
    execute
  ];
}
