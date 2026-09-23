{
  jq,
  writeShellApplication,
}:
writeShellApplication {
  name = "claude-statusline";
  text = ''
    exec ${jq}/bin/jq -rf ${./statusline.jq}
  '';
}
