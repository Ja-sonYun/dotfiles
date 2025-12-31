{ pkgs, ... }:
let
  outputHash = pkgs.hashfile."aws-documentation";
in

pkgs.lib.pip.mkPipGlobalPackageDerivation {
  inherit pkgs outputHash;
  name = "awslabs.aws-documentation-mcp-server";
  packages = [
    "awslabs.aws-documentation-mcp-server==1.1.14"
  ];
  exposedBinaries = [
    "awslabs.aws-documentation-mcp-server"
  ];
}
