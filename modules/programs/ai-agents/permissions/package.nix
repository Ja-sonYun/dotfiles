{
  antigravity ? false,
  callPackage,
  python3,
  writeShellApplication,
}:
let
  hookLibrary = callPackage ../hooks/runtime { inherit python3; };
  python = if antigravity then python3.withPackages (_: [ hookLibrary ]) else python3;
in
writeShellApplication {
  name = "ai-agent-permissions";
  text = ''
    exec ${python}/bin/python ${./permissions.py} "$@"
  '';
}
