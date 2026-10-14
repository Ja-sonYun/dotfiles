{
  lib,
  python3,
  git,
  redact,
}:
python3.pkgs.buildPythonApplication {
  pname = "pi-rules";
  version = "0.1.0";
  src = ./.;
  pyproject = true;

  build-system = [ python3.pkgs.hatchling ];
  dependencies = with python3.pkgs; [
    httpx
    pydantic
    psutil
  ];

  makeWrapperArgs = [
    "--prefix PATH : ${
      lib.makeBinPath [
        git
        redact
      ]
    }"
  ];
  meta.mainProgram = "pi-rules-check";
}
