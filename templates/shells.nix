# All devShell definitions, composed from lib.nix fragments.
{
  pkgs,
  tlib,
}:
let
  inherit (tlib) compose;

  python311 = tlib.mkPython { version = "311"; };
  python312 = tlib.mkPython { version = "312"; };
  python313 = tlib.mkPython { version = "313"; };
  node = tlib.mkNode;
  terraform = tlib.mkTerraform;
  aws = tlib.mkAws;
  gcloud = tlib.mkGcloud;
  azure = tlib.mkAzure;
  rust = tlib.mkRust { };
  rustWasm = tlib.mkRust {
    extraTargets = [ "wasm32-unknown-unknown" ];
    extraPackages = [ pkgs.wasm-pack ];
  };
in
{
  # === Base shells ===

  python311 = compose [ python311 ];
  python312 = compose [ python312 ];
  python313 = compose [ python313 ];
  node20 = compose [ node ];
  go = compose [ tlib.mkGo ];
  rust-stable = compose [ rust ];
  ruby = compose [ tlib.mkRuby ];
  elixir = compose [ tlib.mkElixir ];
  c-cpp = compose [ tlib.mkCCpp ];
  zig = compose [ tlib.mkZig ];

  # === Terraform stacks ===

  terraform = compose [ terraform ];
  terraform-aws = compose [
    terraform
    aws
  ];
  terraform-aws-node20 = compose [
    terraform
    aws
    node
  ];
  terraform-aws-node20-python311 = compose [
    terraform
    aws
    node
    python311
  ];
  terraform-aws-node20-python312 = compose [
    terraform
    aws
    node
    python312
  ];
  terraform-azure = compose [
    terraform
    azure
  ];
  terraform-gcloud = compose [
    terraform
    gcloud
  ];
  terraform-gcloud-python311 = compose [
    terraform
    gcloud
    python311
  ];

  # === Composite stacks ===

  aws-node20-python311 = compose [
    aws
    node
    python311
  ];
  node20-rust = compose [
    node
    rustWasm
  ];
  node20-rust-aws = compose [
    node
    rustWasm
    aws
  ];

}
