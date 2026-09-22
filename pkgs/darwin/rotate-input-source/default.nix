{
  writeShellApplication,
  coreutils,
  macism,
  select-input-source,
}:
writeShellApplication {
  name = "rotate-input-source";
  runtimeInputs = [
    coreutils
    macism
    select-input-source
  ];
  text = builtins.readFile ./rotate-input-source.sh;
}
