{ lib }:
{
  mkOptions =
    defaultAll:
    lib.genAttrs [ "skills" "mcpServers" "agents" ] (
      resource:
      lib.mkOption {
        default = { };
        description = ''
          Shared ${resource} selected for this instance.
          Unknown names in include or exclude cause an evaluation error.
        '';
        type = lib.types.submodule {
          options = {
            include = lib.mkOption {
              type = lib.types.either (lib.types.enum [ "all" ]) (lib.types.listOf lib.types.str);
              default = if defaultAll then "all" else [ ];
              description = "Names to sync, or all catalog entries. Defaults to all for the default profile and none otherwise.";
            };

            exclude = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              description = "Catalog names excluded from the selection, taking precedence over include.";
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
