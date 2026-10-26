{
  lib,
  runCommand,
  makeWrapper,
  nodejs,
  typescript,
  pi-runtime,
}:
runCommand "slack-message-review"
  {
    nativeBuildInputs = [
      makeWrapper
      typescript
    ];
    meta = {
      platforms = lib.platforms.darwin;
      mainProgram = "slack-message-review";
    };
  }
  ''
    mkdir -p "$out/bin" "$out/lib/slack-message-review"
    cp ${./.}/*.mts ${./.}/*.ts ${./.}/tsconfig.*.json .
    ln -s ${pi-runtime}/lib/node_modules/dotfiles-pi/node_modules node_modules
    tsc -p tsconfig.node.json
    tsc -p tsconfig.browser.json
    cp compiled/*.mjs "$out/lib/slack-message-review/"
    cp browser/*.js "$out/lib/slack-message-review/"
    makeWrapper ${lib.getExe nodejs} "$out/bin/slack-message-review" \
      --add-flags "$out/lib/slack-message-review/start.mjs"
  ''
