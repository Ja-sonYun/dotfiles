{ lib, buildGoModule }:
buildGoModule {
  pname = "ai-agent-hook-runner";
  version = "0.1.0";
  src = lib.cleanSource ./runner;
  vendorHash = null;
  meta.mainProgram = "ai-agent-hook-runner";
}
