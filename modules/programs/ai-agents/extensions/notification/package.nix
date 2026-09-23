{
  callPackage,
  python3,
  notifycmd,
  writeShellApplication,
}:
let
  hookLibrary = callPackage ../../hooks/runtime { };
  python = python3.withPackages (_: [ hookLibrary ]);
in
writeShellApplication {
  name = "ai-agent-notification";
  text = ''
    exec ${python}/bin/python ${./notification.py} ${notifycmd}/bin/notifycmd "$@"
  '';
}
