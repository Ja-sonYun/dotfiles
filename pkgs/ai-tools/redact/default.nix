{
  lib,
  buildGoModule,
  betterleaks,
}:
buildGoModule {
  pname = "redact";
  inherit (betterleaks) version src vendorHash;

  subPackages = [ "cmd/redact" ];
  env.CGO_ENABLED = 0;
  doCheck = false;

  postConfigure = ''
    mkdir -p cmd/redact
    cp ${./main.go} cmd/redact/main.go
    cp ${./redact.go} cmd/redact/redact.go
    cp ${./rules.go} cmd/redact/rules.go
    substituteInPlace cmd/redact/main.go \
      --replace-fail '@COMMON_RULES_PATH@' "$out/share/redact/common-rules.txt"
  '';

  postInstall = ''
    install -Dm444 ${./common-rules.txt} "$out/share/redact/common-rules.txt"
  '';

  meta = {
    description = "Redact credentials in text and wrapped command inputs";
    mainProgram = "redact";
    platforms = lib.platforms.unix;
  };
}
