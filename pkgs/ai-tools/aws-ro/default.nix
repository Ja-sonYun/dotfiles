{
  awscli2,
  fetchurl,
  lib,
  python3,
  runCommand,
  stdenvNoCC,
}:
let
  awsLabsRevision = "015ec459d7fcc853904684b28c78fabaa83b3529";
  apiMetadata = fetchurl {
    url = "https://raw.githubusercontent.com/awslabs/mcp/${awsLabsRevision}/src/aws-api-mcp-server/awslabs/aws_api_mcp_server/core/data/api_metadata.json";
    hash = "sha256-o0N61o1CmM2iWIRAWdnZBk+x7du23CpHqpOKulRWw1Y=";
  };

  package = stdenvNoCC.mkDerivation {
    pname = "aws-ro";
    version = "0";
    dontUnpack = true;

    installPhase = ''
      runHook preInstall

      mkdir -p "$out/bin" "$out/share/aws-ro"
      substitute ${./aws_ro.py} "$out/bin/aws-ro" \
        --replace-fail '@AWS_PATH@' '${awscli2}/bin/aws' \
        --replace-fail '@METADATA_PATH@' "$out/share/aws-ro/api_metadata.json"
      chmod +x "$out/bin/aws-ro"
      ln -s ${awscli2}/bin/aws "$out/bin/aws"
      ln -s ${apiMetadata} "$out/share/aws-ro/api_metadata.json"

      runHook postInstall
    '';

    meta = {
      description = "Run AWS CLI operations classified as read-only";
      homepage = "https://github.com/awslabs/mcp/tree/${awsLabsRevision}/src/aws-api-mcp-server";
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
      ${python3}/bin/python -m unittest discover -s . -p 'test_*.py'
      test "$(readlink ${package}/bin/aws)" = "${awscli2}/bin/aws"
      touch "$out"
    '';
  };
})
