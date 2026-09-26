{
  gnused,
  symlinkJoin,
  writeShellScriptBin,
}:
let
  readOnly = writeShellScriptBin "sed" ''
    set -euo pipefail

    reject() {
      printf 'sed: %s. Request approval to use sed-w for unrestricted operations.\n' "$1" >&2
      exit 2
    }

    options=()
    operands=()
    while (( $# > 0 )); do
      argument="$1"
      shift
      case "$argument" in
        --)
          operands+=("$@")
          break
          ;;
        --quiet|--silent|--regexp-extended|--separate|--unbuffered|--null-data|--binary|--posix|--debug|--sandbox|--help|--version)
          options+=("$argument")
          ;;
        --expression|--file|--line-length)
          (( $# > 0 )) || reject "missing argument for $argument"
          options+=("$argument=$1")
          shift
          ;;
        --expression=*|--file=*|--line-length=*)
          options+=("$argument")
          ;;
        --*)
          reject "option $argument is not allowed in read-only mode"
          ;;
        -?*)
          short_options="''${argument:1}"
          while [[ -n "$short_options" ]]; do
            option="''${short_options:0:1}"
            short_options="''${short_options:1}"
            case "$option" in
              n|E|r|s|u|z|b)
                options+=("-$option")
                ;;
              e|f|l)
                if [[ -n "$short_options" ]]; then
                  value="$short_options"
                  short_options=""
                else
                  (( $# > 0 )) || reject "missing argument for -$option"
                  value="$1"
                  shift
                fi
                options+=("-$option" "$value")
                ;;
              *)
                reject "option -$option is not allowed in read-only mode"
                ;;
            esac
          done
          ;;
        *)
          operands+=("$argument")
          ;;
      esac
    done

    # Sandbox rejects script commands, but in-place options need the allowlist above.
    # https://www.gnu.org/software/sed/manual/html_node/Command_002dLine-Options.html
    if ${gnused}/bin/sed --sandbox "''${options[@]}" -- "''${operands[@]}"; then
      exit 0
    else
      result=$?
      if [[ "$result" -eq 1 ]]; then
        printf 'sed: sandboxed operations cannot use e/r/w; request approval to use sed-w if needed.\n' >&2
      fi
      exit "$result"
    fi
  '';

  writable = writeShellScriptBin "sed-w" ''
    exec ${gnused}/bin/sed "$@"
  '';
in
symlinkJoin {
  name = "sed-readonly";
  paths = [
    readOnly
    writable
  ];
  meta = {
    description = "Read-only sed with a separate unrestricted sed-w command";
    mainProgram = "sed";
    inherit (gnused.meta) homepage license platforms;
  };
}
