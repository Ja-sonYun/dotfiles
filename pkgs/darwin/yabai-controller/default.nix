{
  lib,
  buildGoModule,
  logClientSource ? ../../cli-tools/dotfiles-log/clients,
}:
buildGoModule {
  pname = "yabai-controller";
  version = "0.1.0";

  src = ./.;
  postPatch = ''
    mkdir -p internal/logclient
    cp ${logClientSource}/go/client.go internal/logclient/client.go
  '';
  vendorHash = null;
  env.CGO_ENABLED = 0;
  subPackages = [ "." ];
  ldflags = [
    "-s"
    "-w"
  ];
  doCheck = false;

  meta = {
    description = "Resident command controller for yabai";
    mainProgram = "yabai-controller";
    platforms = lib.platforms.darwin;
  };
}
