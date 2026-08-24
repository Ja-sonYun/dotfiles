{
  macism,
  skhd,
  writeShellApplication,
}:

writeShellApplication {
  name = "select-input-source";
  runtimeInputs = [
    macism
    skhd
  ];
  text = builtins.readFile ./select-input-source.sh;
}
