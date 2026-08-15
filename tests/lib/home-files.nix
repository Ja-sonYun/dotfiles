{
  lib,
  home,
  pkgs,
}:
let
  fileNames = builtins.attrNames home.file;
  relative = file: lib.removePrefix "${home.homeDirectory}/" file;
  resolve = file: if builtins.hasAttr file home.file then file else "${home.homeDirectory}/${file}";
  entry = file: home.file.${resolve file};
in
{
  generated =
    prefixes:
    builtins.sort builtins.lessThan (
      map (file: "~/${relative file}") (
        builtins.filter (
          file: builtins.any (prefix: lib.hasPrefix prefix (relative file)) prefixes
        ) fileNames
      )
    );

  source = file: (entry file).source or null;

  materialized =
    file:
    let
      value = entry file;
      name = lib.strings.sanitizeDerivationName (relative (resolve file));
    in
    value.source or (
      if value ? text then
        pkgs.writeText "home-file-${name}" value.text
      else
        throw "home.file ${file} has neither source nor text"
    );
}
