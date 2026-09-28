{
  buildGoModule,
  callPackage,
  git,
  lib,
  python3,
  redact,
  symlinkJoin,
  uv,
}:
let
  hookLibrary = callPackage ../../hooks/runtime { inherit python3; };
  arguments = {
    root = ./.;
    python = python3;
    runtimeInputs = [
      git
      redact
    ];
    extraPythonPaths = [
      "${hookLibrary}/${python3.sitePackages}"
      "${python3.pkgs.psutil}/${python3.sitePackages}"
    ];
  };
in
symlinkJoin {
  name = "ai-agent-rules";
  paths = [
    (buildGoModule {
      pname = "ai-agent-rules-client";
      version = "0.1.0";
      src = lib.cleanSource ./client;
      vendorHash = null;
      meta.mainProgram = "ai-agent-rules-client";
    })
    (uv.asPackage (
      arguments
      // {
        name = "ai-agent-rules-server";
        entrypoint = "ai_agent_rules.server:main";
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
