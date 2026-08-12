{
  lib,
  data,
}:
let
  keysWith =
    category: decision:
    builtins.filter (key: category.${key} == decision) (builtins.attrNames category);

  codexPrefix =
    pattern:
    let
      tokens = builtins.filter (token: token != "") (lib.splitString " " pattern);
      leading =
        builtins.foldl'
          (
            result: token:
            if result.done || lib.hasInfix "*" token then
              result // { done = true; }
            else
              result // { count = result.count + 1; }
          )
          {
            count = 0;
            done = false;
          }
          tokens;
      concrete = builtins.genList (index: builtins.elemAt tokens index) leading.count;
      rest = builtins.genList (index: builtins.elemAt tokens (leading.count + index)) (
        builtins.length tokens - leading.count
      );
    in
    if concrete != [ ] && (rest == [ ] || rest == [ "*" ]) then concrete else null;

  codexDecision = {
    allow = "allow";
    ask = "prompt";
    deny = "forbidden";
  };

  codexRule =
    decision: pattern:
    let
      prefix = codexPrefix pattern;
    in
    if prefix == null then
      null
    else
      ''prefix_rule(pattern = [${
        lib.concatMapStringsSep ", " (token: "\"${token}\"") prefix
      }], decision = "${codexDecision.${decision}}")'';

  codexRules = lib.unique (
    builtins.filter (rule: rule != null) (
      lib.concatMap
        (
          decision:
          map (codexRule decision) (builtins.filter (pattern: pattern != "*") (keysWith data.bash decision))
        )
        [
          "allow"
          "deny"
          "ask"
        ]
    )
  );

  codexMcpServers =
    builtins.listToAttrs (
      map (name: lib.nameValuePair name { default_tools_approval_mode = "approve"; }) (
        builtins.filter (
          name: !(lib.hasPrefix "mcp_" name) && !(lib.hasInfix ":" name) && !(lib.hasSuffix "_*" name)
        ) (keysWith data.mcp "allow")
      )
    )
    // builtins.mapAttrs (_: _: { default_tools_approval_mode = "writes"; }) (
      data.mcp_readonly_tools or { }
    );

  allowPaths = builtins.filter (path: path != "*") (keysWith data.path "allow");
  denyPaths = builtins.filter (path: path != "*") (keysWith data.path "deny");
  isWorkspaceRelative =
    path: !(lib.hasPrefix "~" path) && !(lib.hasPrefix "/" path) && !(lib.hasInfix ".." path);
  absoluteAllowPaths = builtins.filter (path: !(isWorkspaceRelative path)) allowPaths;
  workspaceDenyPaths = builtins.filter isWorkspaceRelative denyPaths;
  absoluteDenyPaths = builtins.filter (path: !(isWorkspaceRelative path)) denyPaths;

  claudeBashRules =
    decision:
    map (pattern: "Bash(${pattern})") (
      builtins.filter (pattern: pattern != "*") (keysWith data.bash decision)
    );

  claudeMcpServers = builtins.filter (
    name: !(lib.hasPrefix "mcp_" name) && !(lib.hasInfix ":" name) && !(lib.hasSuffix "_*" name)
  ) (builtins.attrNames data.mcp);

  claudeReadonlyToolRules = lib.concatLists (
    lib.mapAttrsToList (
      server: tools: map (tool: "mcp__plugin_claude-code-home-manager_${server}__${tool}") tools
    ) (data.mcp_readonly_tools or { })
  );

  piReserved = [
    "*"
    "bash"
    "mcp"
    "mcp_readonly_tools"
    "path"
    "skill"
    "external_directory"
  ];
  piGlobalDefault = data."*";
  piToolKeys = builtins.filter (key: !(builtins.elem key piReserved)) (builtins.attrNames data);
  piToolDecisions = lib.genAttrs piToolKeys (key: data.${key});
  piPathKeys = builtins.filter (path: path != "*") (builtins.attrNames data.path);
  piPathTools = builtins.listToAttrs (
    lib.concatMap (path: [
      (lib.nameValuePair "read:${path}" data.path.${path})
      (lib.nameValuePair "edit:${path}" data.path.${path})
      (lib.nameValuePair "write:${path}" data.path.${path})
    ]) piPathKeys
  );
  piReadonlyToolDecisions = builtins.listToAttrs (
    lib.concatLists (
      lib.mapAttrsToList (
        server: tools: map (tool: lib.nameValuePair "${server}_${tool}" "allow") tools
      ) (data.mcp_readonly_tools or { })
    )
  );
  piExternalKeys = builtins.filter (key: key != "*") (builtins.attrNames data.external_directory);
  piExternalSpecial = builtins.listToAttrs (
    map (
      key: lib.nameValuePair "external_directory:${key}" data.external_directory.${key}
    ) piExternalKeys
  );
in
{
  codex = {
    rules = lib.concatStringsSep "\n" codexRules + "\n";
    profile = {
      extends = ":workspace";
      filesystem =
        builtins.listToAttrs (
          map (path: lib.nameValuePair path "write") absoluteAllowPaths
          ++ map (path: lib.nameValuePair path "deny") absoluteDenyPaths
        )
        // {
          ":workspace_roots" = builtins.listToAttrs (
            map (path: lib.nameValuePair ("**/" + path) "deny") workspaceDenyPaths
          );
        };
      network.enabled = true;
    };
    mcpServers = codexMcpServers;
  };

  claude = {
    allow =
      lib.optional (data.read == "allow") "Read(**)"
      ++ lib.optional ((data.edit or "ask") == "allow") "Edit(**)"
      ++ lib.optional ((data.write or "ask") == "allow") "Write(**)"
      ++ lib.optional (data.web_search == "allow") "WebSearch"
      ++ lib.optional (data.web_fetch == "allow") "WebFetch(domain:*)"
      ++ map (key: if key == "*" then "Skill" else "Skill(${key})") (keysWith data.skill "allow")
      ++ claudeBashRules "allow"
      ++ map (server: "mcp__plugin_claude-code-home-manager_${server}__*") claudeMcpServers
      ++ claudeReadonlyToolRules;
    ask = claudeBashRules "ask";
    deny =
      lib.concatMap (path: [
        "Read(${path})"
        "Edit(${path})"
      ]) (builtins.filter (path: path != "*") (keysWith data.path "deny"))
      ++ claudeBashRules "deny"
      ++ lib.optional (data.read == "deny") "Read(**)"
      ++ lib.optional ((data.edit or "ask") == "deny") "Edit(**)"
      ++ lib.optional ((data.write or "ask") == "deny") "Write(**)";
  };

  pi = {
    defaultPolicy = {
      tools = piGlobalDefault;
      bash = piGlobalDefault;
      mcp = piGlobalDefault;
      skills = data.skill."*" or piGlobalDefault;
      special = data.external_directory."*" or piGlobalDefault;
    };
    tools = piToolDecisions // piPathTools;
    inherit (data) bash;
    mcp = data.mcp // piReadonlyToolDecisions;
    skills = data.skill;
    special = {
      external_directory = data.external_directory."*" or piGlobalDefault;
    }
    // piExternalSpecial;
  };
}
