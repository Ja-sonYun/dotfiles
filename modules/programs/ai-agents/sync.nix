{ lib }:
{
  mkOptions =
    defaultAll:
    lib.genAttrs [ "skills" "mcpServers" "agents" ] (
      resource:
      lib.mkOption {
        default = { };
        description = "Shared ${resource} for this instance.";
        type = lib.types.submodule {
          options = {
            include = lib.mkOption {
              type = lib.types.either (lib.types.enum [ "all" ]) (lib.types.listOf lib.types.str);
              default = if defaultAll then "all" else [ ];
              description = "Names to sync, or all entries.";
            };

            exclude = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              description = "Excluded names; overrides include.";
            };
          };
        };
      }
    );

  select =
    path: selection: catalog:
    let
      available = builtins.attrNames catalog;
      included = if selection.include == "all" then available else selection.include;
      unknown = lib.subtractLists available (lib.unique (included ++ selection.exclude));
    in
    if unknown != [ ] then
      throw "${path}: unknown names: ${lib.concatStringsSep ", " unknown}."
    else
      lib.filterAttrs (
        name: _: builtins.elem name included && !(builtins.elem name selection.exclude)
      ) catalog;
}
