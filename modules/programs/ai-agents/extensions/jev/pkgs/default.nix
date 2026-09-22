{
  callPackage,
  git,
  python3,
  symlinkJoin,
  writeShellApplication,
}:
let
  hookLibrary = callPackage ../../../hooks/runtime { };
  runtime = python3.pkgs.buildPythonPackage {
    pname = "ai-agent-jev";
    version = "0.1.0";
    format = "other";
    src = ./src;
    dontBuild = true;
    propagatedBuildInputs = [
      hookLibrary
      python3.pkgs.mcp
      python3.pkgs.pydantic
    ];

    installPhase = ''
      runHook preInstall
      mkdir -p "$out/${python3.sitePackages}"
      cp -r ai_agent_jev "$out/${python3.sitePackages}/"
      runHook postInstall
    '';
  };
  python = python3.withPackages (_: [ runtime ]);
in
symlinkJoin {
  name = "ai-agent-jev";
  paths = [
    (writeShellApplication {
      name = "ai-agent-jev-hook";
      runtimeInputs = [ git ];
      text = ''
        exec ${python}/bin/python -m ai_agent_jev.hooks "$@"
      '';
    })
    (writeShellApplication {
      name = "ai-agent-jev-mcp";
      runtimeInputs = [ git ];
      text = ''
        exec ${python}/bin/python -m ai_agent_jev.mcp_server "$@"
      '';
    })
  ];
}
