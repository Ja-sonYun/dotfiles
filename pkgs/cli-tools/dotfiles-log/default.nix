{
  lib,
  buildGoModule,
  writeText,
  logFile ? "",
  socketPath,
  maxBytes ? 1048576,
  level ? "info",
}:
buildGoModule {
  pname = "dotfiles-log";
  version = "0.1.0";
  src = ./.;
  vendorHash = null;
  env.CGO_ENABLED = 0;
  postPatch = ''
    cp ${
      writeText "dotfiles-log-config.json" (
        builtins.toJSON {
          file = logFile;
          inherit maxBytes level socketPath;
        }
      )
    } config.json
  '';
  ldflags = [
    "-s"
    "-w"
  ];
  doCheck = false;
  meta = {
    description = "Bounded shared JSONL event logger";
    mainProgram = "dotfiles-log";
    platforms = lib.platforms.unix;
  };
}
