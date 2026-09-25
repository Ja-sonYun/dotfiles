{
  python3,
  writeShellApplication,
}:
writeShellApplication {
  name = "ai-agent-permissions";
  text = ''
    exec ${python3}/bin/python ${./permissions.py} "$@"
  '';
}
