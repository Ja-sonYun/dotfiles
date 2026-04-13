# All devShell definitions, composed from lib.nix fragments.
{
  pkgs,
  pkgs-terraform,
  system,
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
  python-uv = compose [ python313 ]; # alias
  node20 = compose [ node ];
  go = compose [ tlib.mkGo ];
  rust-stable = compose [ rust ];
  ruby = compose [ tlib.mkRuby ];
  elixir = compose [ tlib.mkElixir ];
  c-cpp = compose [ tlib.mkCCpp ];
  zig = compose [ tlib.mkZig ];

  # === Terraform stacks ===

  terraform = compose [ terraform ];
  terraform-aws = compose [ terraform aws ];
  terraform-aws-node20 = compose [ terraform aws node ];
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
  terraform-azure = compose [ terraform azure ];
  terraform-gcloud = compose [ terraform gcloud ];
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
  node20-rust = compose [ node rustWasm ];
  node20-rust-aws = compose [
    node
    rustWasm
    aws
  ];

  # === Legacy aliases ===

  "go1.24" = compose [ tlib.mkGo ];
  "ruby3.3" = compose [ tlib.mkRuby ];
  "terraform1.8.2" = compose [ terraform ];
  "terraform1.8.2-aws" = compose [ terraform aws ];
  "terraform1.8.2-aws-node20" = compose [ terraform aws node ];
  "terraform1.8.2-aws-node20-python310" = compose [
    terraform
    aws
    node
    python311
  ];
  "terraform1.8.2-aws-node20-python312" = compose [
    terraform
    aws
    node
    python312
  ];
  "terraform1.8.2-azure" = compose [ terraform azure ];

  # Legacy python310 aliases (now python311)
  python310 = compose [ python311 ];
  aws-node20-python310 = compose [
    aws
    node
    python311
  ];
  terraform-aws-node20-python310 = compose [
    terraform
    aws
    node
    python311
  ];
  terraform-gcloud-python310 = compose [
    terraform
    gcloud
    python311
  ];
}
