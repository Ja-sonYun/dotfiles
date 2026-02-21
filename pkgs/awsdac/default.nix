{ lib, buildGoModule, fetchFromGitHub }:

buildGoModule rec {
  pname = "awsdac";
  version = "0.22.4";

  src = fetchFromGitHub {
    owner = "awslabs";
    repo = "diagram-as-code";
    rev = "v${version}";
    hash = "sha256-MhIGrkP/wpO+gf1SMSaO1CQVLRxFY48XQnnN6HELUtg=";
  };

  subPackages = [
    "cmd/awsdac"
    "cmd/awsdac-mcp-server"
  ];

  vendorHash = "sha256-1yQnjQfOY69lTpPjI9sA9SwdeMx+iAK6QUEVqQOnprY=";

  doCheck = false;

  meta = with lib; {
    description = "AWS architecture diagrams as code";
    homepage = "https://github.com/awslabs/diagram-as-code";
    license = licenses.asl20;
    mainProgram = "awsdac";
  };
}
