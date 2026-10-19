{ pkgs }:
{
  runtime,
  bundle,
  devBundle ? bundle,
  devNodePath ? "${devBundle}/node_modules",
  settings ? (import ../config { inherit pkgs; }).settings,
}:
let
  inherit (pkgs) lib;
  jsonFormat = pkgs.formats.json { };
  settingsFile = jsonFormat.generate "pi-settings.json" settings;
  selectBundle = ''
    if [ "''${PI_CODING_AGENT_DIR:-}" = "$HOME/.pi/agent-dev" ]; then
      export PI_RESOURCE_PACKAGE="''${PI_RESOURCE_PACKAGE:-${devBundle}}"
      export NODE_PATH="$PI_RESOURCE_PACKAGE/node_modules:"${lib.escapeShellArg devNodePath}"''${NODE_PATH:+:$NODE_PATH}"
    else
      export PI_RESOURCE_PACKAGE="''${PI_RESOURCE_PACKAGE:-${bundle}}"
      export NODE_PATH="$PI_RESOURCE_PACKAGE/node_modules''${NODE_PATH:+:$NODE_PATH}"
    fi
    profileDir="''${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"
    case "$profileDir" in
      '~/'*) profileDir="$HOME/''${profileDir#\~/}" ;;
    esac
    if [ ! -e "$profileDir/settings.json" ] && [ ! -L "$profileDir/settings.json" ]; then
      ${pkgs.coreutils}/bin/mkdir -p "$profileDir"
      ${pkgs.coreutils}/bin/cp --no-clobber ${settingsFile} "$profileDir/settings.json"
      ${pkgs.coreutils}/bin/chmod u+w "$profileDir/settings.json"
    fi
    if [ -n "''${PI_SKILLS_DIR:-}" ]; then
      set -- --skill "$PI_SKILLS_DIR" "$@"
    fi
    set -- -e "$PI_RESOURCE_PACKAGE" "$@"
  '';
in
pkgs.runCommand "pi-configured"
  {
    nativeBuildInputs = [ pkgs.makeWrapper ];
    meta.mainProgram = "pi";
  }
  ''
    mkdir -p "$out/bin"
    makeWrapper ${pkgs.python3}/bin/python "$out/bin/pi-mcp-instructions" \
      --add-flags ${lib.escapeShellArg (toString ../mcp/instructions.py)}
    makeWrapper ${runtime}/bin/pi "$out/bin/pi" \
      --prefix PATH : "$out/bin" \
      --suffix PATH : ${
        lib.makeBinPath [
          pkgs.git
          pkgs.ripgrep
          pkgs.shfmt
          pkgs.pi-extensions.permissions.evaluator
        ]
      } \
      --run ${lib.escapeShellArg selectBundle}
    makeWrapper ${runtime}/bin/pi-dev "$out/bin/pi-dev" --prefix PATH : "$out/bin"
  ''
