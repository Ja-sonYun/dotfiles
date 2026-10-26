{
  lib,
  runCommand,
  makeWrapper,
  nodejs,
  typescript,
  pi-runtime,
}:
runCommand "slack-thread-summary"
  {
    nativeBuildInputs = [
      makeWrapper
      typescript
    ];
    meta = {
      platforms = lib.platforms.darwin;
      mainProgram = "slack-thread-summary";
    };
  }
  ''
    mkdir -p "$out/bin" "$out/lib/slack-thread-summary"
    cp ${./.}/*.mts ${./.}/*.ts ${./.}/tsconfig.*.json .
    ln -s ${pi-runtime}/lib/node_modules/dotfiles-pi/node_modules node_modules
    tsc -p tsconfig.node.json
    tsc -p tsconfig.browser.json
    cp compiled/*.mjs "$out/lib/slack-thread-summary/"
    cp browser/*.js "$out/lib/slack-thread-summary/"
    makeWrapper ${lib.getExe nodejs} "$out/bin/slack-thread-summary" \
      --add-flags "$out/lib/slack-thread-summary/start.mjs"
  ''
