{
  python311 = {
    description = "Python 3.11 + uv";
    tags = [
      "python"
      "uv"
    ];
  };
  python312 = {
    description = "Python 3.12 + uv";
    tags = [
      "python"
      "uv"
    ];
  };
  python313 = {
    description = "Python 3.13 + uv";
    tags = [
      "python"
      "uv"
    ];
  };
  node20 = {
    description = "Node.js 20 + pnpm + yarn";
    tags = [
      "node"
      "javascript"
      "typescript"
    ];
  };
  go = {
    description = "Go 1.25 + gotools + golangci-lint";
    tags = [
      "go"
      "golang"
    ];
  };
  rust-stable = {
    description = "Rust stable + cargo tools + rust-analyzer";
    tags = [
      "rust"
      "cargo"
    ];
  };
  ruby = {
    description = "Ruby 3.3";
    tags = [ "ruby" ];
  };
  elixir = {
    description = "Elixir 1.17 + Erlang 27 + Node.js 20";
    tags = [
      "elixir"
      "erlang"
      "beam"
    ];
  };
  c-cpp = {
    description = "C/C++ with clang, gcc, cmake, ninja, gtest";
    tags = [
      "c"
      "cpp"
      "cmake"
    ];
  };
  zig = {
    description = "Zig + zls + lldb";
    tags = [ "zig" ];
  };
  terraform = {
    description = "Terraform 1.8.2";
    tags = [
      "terraform"
      "iac"
    ];
  };
  terraform-aws = {
    description = "Terraform 1.8.2 + AWS CLI";
    tags = [
      "terraform"
      "aws"
      "iac"
    ];
  };
  terraform-aws-node20 = {
    description = "Terraform 1.8.2 + AWS CLI + Node.js 20";
    tags = [
      "terraform"
      "aws"
      "node"
      "iac"
    ];
  };
  terraform-aws-node20-python311 = {
    description = "Terraform 1.8.2 + AWS CLI + Node.js 20 + Python 3.11";
    tags = [
      "terraform"
      "aws"
      "node"
      "python"
      "iac"
    ];
  };
  terraform-aws-node20-python312 = {
    description = "Terraform 1.8.2 + AWS CLI + Node.js 20 + Python 3.12";
    tags = [
      "terraform"
      "aws"
      "node"
      "python"
      "iac"
    ];
  };
  terraform-azure = {
    description = "Terraform 1.8.2 + Azure CLI";
    tags = [
      "terraform"
      "azure"
      "iac"
    ];
  };
  terraform-gcloud = {
    description = "Terraform 1.8.2 + Google Cloud SDK + Helm";
    tags = [
      "terraform"
      "gcloud"
      "gcp"
      "iac"
    ];
  };
  terraform-gcloud-python311 = {
    description = "Terraform 1.8.2 + Google Cloud SDK + Python 3.11";
    tags = [
      "terraform"
      "gcloud"
      "gcp"
      "python"
      "iac"
    ];
  };
  aws-node20-python311 = {
    description = "AWS CLI + Node.js 20 + Python 3.11";
    tags = [
      "aws"
      "node"
      "python"
    ];
  };
  node20-rust = {
    description = "Node.js 20 + Rust stable (wasm)";
    tags = [
      "node"
      "rust"
      "wasm"
    ];
  };
  node20-rust-aws = {
    description = "Node.js 20 + Rust stable (wasm) + AWS CLI";
    tags = [
      "node"
      "rust"
      "wasm"
      "aws"
    ];
  };
}
