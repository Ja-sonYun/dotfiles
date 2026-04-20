{ pkgs, ... }:

pkgs.lib.mkPackageDerivation {
  inherit pkgs;
  hashKey = "aws-documentation";
  packageManager = "pip";
  packageName = "awslabs.aws-documentation-mcp-server";
  packageVersion = "1.1.20";
  name = "awslabs.aws-documentation-mcp-server";
  exposedBinaries = [
    "awslabs.aws-documentation-mcp-server"
  ];
}
