{
  lib,
  buildGoModule,
}:
buildGoModule {
  pname = "yabai-controller";
  version = "0.1.0";

  src = ./.;
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
