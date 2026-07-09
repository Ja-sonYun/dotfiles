{ pkgs, ... }:

let
  fireHook = pkgs.writeShellScript "pi-fire-hook" ''
    event="''${1:-}"
    subject="''${2:-}"
    [ -n "$event" ] || exit 0
    file="''${PI_HOOKS_FILE:-$HOME/.pi/agent/hooks.json}"
    [ -f "$file" ] || exit 0
    ${pkgs.jq}/bin/jq -r --arg e "$event" --arg s "$subject" '
      (.[$e] // [])[]
      | (.matcher // "") as $m
      | select($m == "" or $m == "*" or ($s | test($m)))
      | .hooks[].command // empty
    ' "$file" | while IFS= read -r cmd; do
      [ -n "$cmd" ] && sh -c "$cmd" &
    done
    wait
  '';
in
pkgs.runCommandLocal "pi-ext-hooks" { passthru = { inherit fireHook; }; } ''
  mkdir -p $out
  substitute ${./index.ts} $out/index.ts --replace-fail '@fireHook@' '${fireHook}'
''
