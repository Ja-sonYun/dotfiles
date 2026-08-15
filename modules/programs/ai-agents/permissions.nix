{
  lib,
  data,
}:
let
  keysWith =
    category: decision:
    builtins.filter (key: category.${key} == decision) (builtins.attrNames category);
  explicitKeys = category: builtins.filter (key: key != "*") (builtins.attrNames category);
  explicitKeysWith =
    category: decision: builtins.filter (key: category.${key} == decision) (explicitKeys category);
  isDirectMcpServer =
    name: !(lib.hasPrefix "mcp_" name) && !(lib.hasInfix ":" name) && !(lib.hasSuffix "_*" name);
  paths = {
    allow = explicitKeysWith data.path "allow";
    read = explicitKeysWith data.path "read";
    deny = explicitKeysWith data.path "deny";
  };
  readonlyMcpTools = data.mcp_readonly_tools or { };
in
{
  codex =
    let
      prefixFor =
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
      decisions = {
        allow = "allow";
        ask = "prompt";
        deny = "forbidden";
      };
      ruleFor =
        decision: pattern:
        let
          prefix = prefixFor pattern;
        in
        if prefix == null then
          null
        else
          ''prefix_rule(pattern = [${
            lib.concatMapStringsSep ", " (token: "\"${token}\"") prefix
          }], decision = "${decisions.${decision}}")'';
      rules = lib.unique (
        builtins.filter (rule: rule != null) (
          lib.concatMap (decision: map (ruleFor decision) (explicitKeysWith data.bash decision)) [
            "allow"
            "deny"
            "ask"
          ]
        )
      );
      mcpServers =
        builtins.listToAttrs (
          map (name: lib.nameValuePair name { default_tools_approval_mode = "approve"; }) (
            builtins.filter isDirectMcpServer (keysWith data.mcp "allow")
          )
        )
        // builtins.mapAttrs (_: _: { default_tools_approval_mode = "writes"; }) readonlyMcpTools;
      isWorkspaceRelative =
        path: !(lib.hasPrefix "~" path) && !(lib.hasPrefix "/" path) && !(lib.hasInfix ".." path);
      absolutePaths = decision: builtins.filter (path: !(isWorkspaceRelative path)) paths.${decision};
      workspacePaths = decision: builtins.filter isWorkspaceRelative paths.${decision};
    in
    {
      rules = lib.concatStringsSep "\n" rules + "\n";
      profile = {
        extends = ":workspace";
        filesystem =
          builtins.listToAttrs (
            map (path: lib.nameValuePair path "write") (absolutePaths "allow")
            ++ map (path: lib.nameValuePair path "read") (absolutePaths "read")
            ++ map (path: lib.nameValuePair path "deny") (absolutePaths "deny")
          )
          // {
            ":workspace_roots" = builtins.listToAttrs (
              map (path: lib.nameValuePair ("**/" + path) "read") (workspacePaths "read")
              ++ map (path: lib.nameValuePair ("**/" + path) "deny") (workspacePaths "deny")
            );
          };
        network.enabled = true;
      };
      inherit mcpServers;
    };

  claude =
    let
      bashRules = decision: map (pattern: "Bash(${pattern})") (explicitKeysWith data.bash decision);
      claudePath = path: if lib.hasPrefix "/" path then "/" + path else path;
      pluginName = "hm";
      mcpServers = builtins.filter isDirectMcpServer (builtins.attrNames data.mcp);
      readonlyToolRules = lib.concatLists (
        lib.mapAttrsToList (
          server: tools: map (tool: "mcp__plugin_${pluginName}_${server}__${tool}") tools
        ) readonlyMcpTools
      );
    in
    {
      allow =
        lib.optional (data.read == "allow") "Read(**)"
        ++ lib.optional ((data.edit or "ask") == "allow") "Edit(**)"
        ++ lib.optional ((data.write or "ask") == "allow") "Write(**)"
        ++ lib.optional (data.web_search == "allow") "WebSearch"
        ++ lib.optional (data.web_fetch == "allow") "WebFetch(domain:*)"
        ++ map (path: "Read(${claudePath path})") paths.read
        ++ lib.concatMap (path: [
          "Edit(${claudePath path})"
          "Write(${claudePath path})"
        ]) paths.allow
        ++ map (key: if key == "*" then "Skill" else "Skill(${key})") (keysWith data.skill "allow")
        ++ bashRules "allow"
        ++ map (server: "mcp__plugin_${pluginName}_${server}__*") mcpServers
        ++ readonlyToolRules;
      ask = bashRules "ask";
      deny =
        map (path: "Edit(${claudePath path})") paths.read
        ++ lib.concatMap (path: [
          "Read(${claudePath path})"
          "Edit(${claudePath path})"
        ]) paths.deny
        ++ bashRules "deny"
        ++ lib.optional (data.read == "deny") "Read(**)"
        ++ lib.optional ((data.edit or "ask") == "deny") "Edit(**)"
        ++ lib.optional ((data.write or "ask") == "deny") "Write(**)";
    };

}
