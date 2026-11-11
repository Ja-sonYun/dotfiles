{
  lib,
  buildGoModule,
}:
buildGoModule {
  pname = "tmux-agent-dashboard";
  version = "0.1.0";
  src = ./.;
  vendorHash = "sha256-uwBJAqN4sIepiiJf9lCDumLqfKJEowQO2tOiSWD3Fig=";
  env.CGO_ENABLED = 0;
  ldflags = [
    "-s"
    "-w"
  ];
  doCheck = false;
  meta = {
    description = "Sidebar for existing tmux agent sessions";
    mainProgram = "tmux-agent-dashboard";
    platforms = lib.platforms.unix;
  };
}
