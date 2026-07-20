let
  allowedTags = [
    "gui"
    "server"
    "gpu"
    "ai"
    "wsl"
  ];
  validateTag =
    context: tag:
    if !builtins.isString tag then
      throw "${context}: tag must be a string"
    else if !builtins.elem tag allowedTags then
      throw "${context}: unknown tag '${tag}'"
    else
      tag;
in
{
  validate =
    context: tags:
    if !builtins.isList tags then
      throw "${context}: tags must be a list"
    else
      let
        validated = map (validateTag context) tags;
      in
      builtins.deepSeq validated validated;

  has = tags: tag: builtins.elem (validateTag "hasTag" tag) tags;
}
