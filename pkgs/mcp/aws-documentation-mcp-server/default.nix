{ pkgs, ... }:

pkgs.lib.mkPackageDerivation {
  inherit pkgs;
  hashKey = "aws-documentation-mcp-server";
  packageManager = "pip";
  packageName = "awslabs.aws-documentation-mcp-server";
  packageVersion = "1.2.0";
  name = "aws-documentation-mcp-server";
  pythonVersion = "312";
  exposedBinaries = [
    "awslabs.aws-documentation-mcp-server"
  ];
}
