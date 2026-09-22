{
  callPackage,
  python3,
  writeShellApplication,
}:
let
  hookLibrary = callPackage ../hooks/runtime { };
  python = python3.withPackages (_: [ hookLibrary ]);
in
writeShellApplication {
  name = "ai-agent-permissions";
  text = ''
    exec ${python}/bin/python ${./permissions.py} "$@"
  '';
}
