{ lib
, stdenv
, fetchurl
, autoPatchelfHook
}:

let
  version = "3.7.5";
  targets = {
    aarch64-darwin = {
      artifact = "aarch64-apple-darwin";
      hash = "sha256-v6V/tzM5begn6w94JDv+j64kVSZ9TxExH/NdQxjiPXc=";
    };
    x86_64-darwin = {
      artifact = "x86_64-apple-darwin";
      hash = "sha256-b0dRvGLUpy3jPH/k/xA2GufOqaTIbbzhBj10+bpTtTY=";
    };
    aarch64-linux = {
      artifact = "aarch64-unknown-linux-gnu";
      hash = "sha256-BOl9x9H7cfbeiWGMTckEleQe3l98egrlBiKjGOpas9k=";
    };
    x86_64-linux = {
      artifact = "x86_64-unknown-linux-gnu";
      hash = "sha256-xYav5kEUFCuuNgtcJ/NhjS++T4K6Sz4GQglvM7Jo5NM=";
    };
  };
  target =
    targets.${stdenv.hostPlatform.system}
      or (throw "lean-ctx is not packaged for ${stdenv.hostPlatform.system}");
in
stdenv.mkDerivation {
  pname = "lean-ctx";
  inherit version;

  src = fetchurl {
    url = "https://github.com/yvgude/lean-ctx/releases/download/v${version}/lean-ctx-${target.artifact}.tar.gz";
    inherit (target) hash;
  };

  sourceRoot = ".";
  dontBuild = true;

  nativeBuildInputs = lib.optionals stdenv.hostPlatform.isLinux [
    autoPatchelfHook
  ];

  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin
    install -m755 lean-ctx $out/bin/lean-ctx

    runHook postInstall
  '';

  meta = {
    homepage = "https://github.com/yvgude/lean-ctx";
    description = "Context compression MCP server and CLI";
    license = lib.licenses.mit;
    mainProgram = "lean-ctx";
    platforms = builtins.attrNames targets;
  };
}
