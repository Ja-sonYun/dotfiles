{
  helpers,
  lib,
  pkgs,
}:
let
  inherit (helpers) fail pluginRelativePath validName;
  namePatterns = [
    "[[:space:]]*name:[[:space:]]*([a-z0-9]([a-z0-9-]*[a-z0-9])?)[[:space:]]*"
    ''[[:space:]]*name:[[:space:]]*"([a-z0-9]([a-z0-9-]*[a-z0-9])?)"[[:space:]]*''
    "[[:space:]]*name:[[:space:]]*'([a-z0-9]([a-z0-9-]*[a-z0-9])?)'[[:space:]]*"
  ];

  skillNameFor =
    marketplace: pluginName: skillRoot:
    let
      skillPath = "${skillRoot}/SKILL.md";
      lines = lib.splitString "\n" (builtins.readFile skillPath);
      body = if lines != [ ] && builtins.head lines == "---" then builtins.tail lines else [ ];
      takeFrontmatter =
        remaining:
        if remaining == [ ] || builtins.head remaining == "---" then
          [ ]
        else
          [ (builtins.head remaining) ] ++ takeFrontmatter (builtins.tail remaining);
      frontmatter = takeFrontmatter body;
      hasClosingDelimiter = builtins.length frontmatter < builtins.length body;
      matches = builtins.filter (match: match != null) (
        map (
          line:
          lib.findFirst (match: match != null) null (map (pattern: builtins.match pattern line) namePatterns)
        ) frontmatter
      );
      name = if builtins.length matches == 1 then builtins.head (builtins.head matches) else null;
    in
    if !hasClosingDelimiter || name == null || !validName name then
      fail marketplace "skill in plugin `${pluginName}` at `${skillRoot}` must have one lowercase kebab-case frontmatter `name`."
    else
      name;

  skillRootsAt =
    marketplace: pluginName: path:
    if !builtins.pathExists path then
      fail marketplace "plugin `${pluginName}` skill path `${path}` does not exist."
    else if builtins.pathExists "${path}/SKILL.md" then
      [ path ]
    else
      let
        directory = builtins.tryEval (builtins.readDir path);
        names =
          if directory.success then
            builtins.attrNames (lib.filterAttrs (_: type: type == "directory") directory.value)
          else
            fail marketplace "plugin `${pluginName}` skill path `${path}` must be a directory.";
        roots = map (name: "${path}/${name}") names;
        missing = builtins.filter (root: !builtins.pathExists "${root}/SKILL.md") roots;
      in
      if roots == [ ] then
        fail marketplace "plugin `${pluginName}` skill path `${path}` contains no skills."
      else if missing != [ ] then
        fail marketplace "plugin `${pluginName}` skill directories are missing SKILL.md: ${lib.concatStringsSep ", " missing}."
      else
        roots;

  convertSkill =
    marketplace: pluginName: skillName: source:
    let
      name = "${pluginName}-${skillName}";
    in
    if !validName skillName then
      fail marketplace "skill `${pluginName}/${skillName}` must use lowercase kebab-case."
    else if builtins.stringLength name > 64 then
      fail marketplace "generated skill name `${name}` exceeds 64 characters."
    else
      {
        inherit
          marketplace
          name
          pluginName
          skillName
          ;
        value =
          pkgs.runCommandLocal "marketplace-skill-${name}"
            {
              nativeBuildInputs = [ pkgs.yq-go ];
              sourceSkillName = skillName;
              targetSkillName = name;
            }
            ''
              set -euo pipefail

              mkdir -p "$out"
              cp -R ${lib.escapeShellArg "${source}/."} "$out"
              chmod -R u+w "$out"

              yq --front-matter=extract --exit-status \
                '(.name | type) == "!!str" and .name != "" and (.description | type) == "!!str" and .description != ""' \
                "$out/SKILL.md" >/dev/null

              source_name="$(yq --front-matter=extract --unwrapScalar '.name' "$out/SKILL.md")"
              if [[ "$source_name" != "$sourceSkillName" ]]; then
                printf 'skill frontmatter name `%s` does not match directory `%s`\n' \
                  "$source_name" "$sourceSkillName" >&2
                exit 1
              fi

              yq --front-matter=process --inplace \
                '.name = strenv(targetSkillName)' "$out/SKILL.md"
            '';
      };
in
marketplace: pluginName: pluginRoot: pluginFiles: pluginAtMarketplaceRoot: useDefault: declarations:
let
  pathsFor =
    declaration:
    if builtins.isString declaration then
      [ declaration ]
    else if builtins.isList declaration && lib.all builtins.isString declaration then
      declaration
    else
      fail marketplace "plugin `${pluginName}` `skills` must be a relative path or list of relative paths.";
  declaredPaths = lib.unique (
    map (path: pluginRelativePath marketplace pluginName "skill path" pluginRoot true path) (
      lib.concatMap pathsFor declarations
    )
  );
  defaultSkillsPath = "${pluginRoot}/skills";
  scanDefault = useDefault && !(pluginAtMarketplaceRoot && declaredPaths != [ ]);
  defaultPaths =
    if !scanDefault || !(pluginFiles ? skills) then
      [ ]
    else if pluginFiles.skills != "directory" then
      fail marketplace "plugin `${pluginName}` has a non-directory `skills` entry."
    else
      [ defaultSkillsPath ];
  rootFallback = lib.optional (
    useDefault
    && declaredPaths == [ ]
    && defaultPaths == [ ]
    && builtins.pathExists "${pluginRoot}/SKILL.md"
  ) pluginRoot;
  skillRoots = lib.unique (
    lib.concatMap (skillRootsAt marketplace pluginName) (defaultPaths ++ declaredPaths ++ rootFallback)
  );
in
map (
  skillRoot:
  convertSkill marketplace pluginName (skillNameFor marketplace pluginName skillRoot) skillRoot
) skillRoots
