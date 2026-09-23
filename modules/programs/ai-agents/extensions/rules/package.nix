{
  callPackage,
  git,
  python3,
  symlinkJoin,
  uv,
}:
let
  hookLibrary = callPackage ../../hooks/runtime { inherit python3; };
  arguments = {
    root = ./.;
    python = python3;
    runtimeInputs = [ git ];
    extraPythonPaths = [ "${hookLibrary}/${python3.sitePackages}" ];
  };
in
symlinkJoin {
  name = "ai-agent-rules";
  paths = [
    (uv.asPackage (
      arguments
      // {
        name = "ai-agent-rules-hook";
        entrypoint = "ai_agent_rules.hooks:main";
      }
    ))
    (uv.asPackage (
      arguments
      // {
        name = "ai-agent-rules-mcp";
        entrypoint = "ai_agent_rules.mcp_server:main";
      }
    ))
  ];
}
