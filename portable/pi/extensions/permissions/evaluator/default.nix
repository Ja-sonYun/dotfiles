{
  lib,
  python3,
  git,
}:
python3.pkgs.buildPythonApplication {
  pname = "pi-permissions-evaluator";
  version = "0.1.0";
  src = ./.;
  pyproject = true;

  build-system = [ python3.pkgs.hatchling ];
  dependencies = with python3.pkgs; [
    pydantic
  ];

  makeWrapperArgs = [
    "--prefix"
    "PATH"
    ":"
    (lib.makeBinPath [ git ])
  ];
  meta.mainProgram = "pi-permissions-evaluator";
}
