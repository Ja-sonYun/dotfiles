{
  config,
  paths,
  ...
}:
let
  repoRoot = ../..;
in
{
  config.lib.file.mkRepoSource =
    {
      path,
      mode ? "store",
    }:
    if mode == "store" then
      repoRoot + "/${path}"
    else if mode == "mutable" then
      config.lib.file.mkOutOfStoreSymlink "${paths.dotfiles}/${path}"
    else
      throw "mkRepoSource: unsupported mode `${mode}`";
}
