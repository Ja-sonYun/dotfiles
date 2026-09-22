{
  lib,
  buildGoModule,
  makeWrapper,
  redact,
}:
buildGoModule {
  pname = "jev";
  version = "0.1.0";

  src = ./.;
  vendorHash = "sha256-uAS/04KDMXNbC5Zmsaj/psU9gxk/KIG36Zy4AUbpKgo=";
  env.CGO_ENABLED = 0;

  nativeBuildInputs = [ makeWrapper ];
  postInstall = ''
    mkdir -p "$out/libexec/jev"
    mv "$out/bin/jev" "$out/libexec/jev/_jev"
    makeWrapper ${redact}/bin/redact "$out/bin/jev" \
      --add-flags "-- $out/libexec/jev/_jev"
  '';

  meta = {
    description = "TypeSafe AI Jev decision CLI";
    mainProgram = "jev";
    platforms = lib.platforms.unix;
  };
}
