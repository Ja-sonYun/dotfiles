{
  awscli2,
  lib,
  makeWrapper,
  runCommand,
  stdenvNoCC,
}:
let
  awsPython = awscli2.python;
  awsPythonPath = lib.makeSearchPath awsPython.sitePackages (
    [ awscli2 ] ++ awsPython.pkgs.requiredPythonModules awscli2.propagatedBuildInputs
  );

  package = stdenvNoCC.mkDerivation {
    pname = "aws-ro";
    version = "0";
    dontUnpack = true;
    nativeBuildInputs = [ makeWrapper ];

    installPhase = ''
      runHook preInstall

      mkdir -p "$out/bin" "$out/share/aws-ro"
      substitute ${./aws_ro.py} "$out/share/aws-ro/aws_ro.py" \
        --replace-fail '@METADATA_PATH@' "$out/share/aws-ro/api_metadata.json"
      makeWrapper ${awsPython.interpreter} "$out/bin/aws-ro" \
        --add-flags "$out/share/aws-ro/aws_ro.py" \
        --set PYTHONPATH '${awsPythonPath}' \
        --set PYTHONNOUSERSITE true \
        --unset NIX_PYTHONPATH \
        --unset PYTHONHOME \
        --prefix PATH : '${lib.makeBinPath ([ awscli2 ] ++ awscli2.propagatedBuildInputs)}'
      ln -s ${awscli2}/bin/aws "$out/bin/aws"
      ln -s ${./api_metadata.json} "$out/share/aws-ro/api_metadata.json"

      runHook postInstall
    '';

    meta = {
      description = "Run AWS CLI operations classified as read-only";
      homepage = "https://docs.aws.amazon.com/service-authorization/latest/reference/service-reference.html";
      license = lib.licenses.asl20;
      mainProgram = "aws-ro";
      platforms = awscli2.meta.platforms;
    };
  };
in
package.overrideAttrs (old: {
  passthru = (old.passthru or { }) // {
    tests.unit = runCommand "aws-ro-unit-test" { } ''
      cp ${./aws_ro.py} aws_ro.py
      cp ${./test_aws_ro.py} test_aws_ro.py
      cp ${./api_metadata.json} api_metadata.json
      env -u PYTHONHOME -u NIX_PYTHONPATH \
        PYTHONPATH='${awsPythonPath}' PYTHONNOUSERSITE=true \
        ${awsPython.interpreter} -m unittest discover -s . -p 'test_*.py'
      test "$(readlink ${package}/bin/aws)" = "${awscli2}/bin/aws"
      touch "$out"
    '';
  };
})
