{
  fetchurl,
  lib,
  makeWrapper,
  stdenvNoCC,
}:
stdenvNoCC.mkDerivation {
  pname = "antigravity-cli";
  version = "1.4.4";

  src = fetchurl {
    url = "https://storage.googleapis.com/antigravity-public/antigravity-cli/1.4.4-4783783166214144/darwin-arm/cli_mac_arm64.tar.gz";
    hash = "sha512-zRLEYJuLRKqUwv5Q7tjziE8azlBlhGMMv/z/QosNVXuIPbDMX7nPzJJSiCnFGYV4KQcFkMFe1tZzrfGRbmCREQ==";
  };

  nativeBuildInputs = [ makeWrapper ];
  dontUnpack = true;
  dontStrip = true;

  installPhase = ''
    runHook preInstall

    tar -xzf "$src" antigravity
    install -Dm755 antigravity "$out/libexec/agy"
    mkdir -p "$out/bin"
    makeWrapper "$out/libexec/agy" "$out/bin/agy" \
      --set AGY_CLI_DISABLE_AUTO_UPDATE true

    runHook postInstall
  '';

  meta = {
    description = "Google Antigravity command-line coding agent";
    homepage = "https://antigravity.google/docs/cli/install/";
    license = lib.licenses.unfree;
    mainProgram = "agy";
    platforms = [ "aarch64-darwin" ];
  };
}
