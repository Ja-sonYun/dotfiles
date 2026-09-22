{ python3 }:
python3.pkgs.buildPythonPackage {
  pname = "ai-agent-hooks";
  version = "0.1.0";
  format = "other";
  dontUnpack = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    package="$out/${python3.sitePackages}/ai_agent_hooks"
    mkdir -p "$package"
    touch "$package/__init__.py"
    cp ${./hook_input.py} "$package/hook_input.py"
    cp ${./edit_input.py} "$package/edit_input.py"
    runHook postInstall
  '';
}
