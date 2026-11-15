{
  lib,
  runCommand,
  makeWrapper,
  nodejs,
  typescript,
  pi-runtime,
}:
runCommand "slack-ai-integration"
  {
    nativeBuildInputs = [
      makeWrapper
      typescript
    ];
    meta = {
      platforms = lib.platforms.darwin;
      mainProgram = "slack-ai-integration";
    };
  }
  ''
    mkdir -p "$out/bin" "$out/lib/slack-ai-integration"
    cp -R ${./.}/. .
    chmod -R u+w .
    ln -s ${pi-runtime}/lib/node_modules/dotfiles-pi/node_modules node_modules
    tsc -p tsconfig.node.json
    tsc -p tsconfig.review.json
    tsc -p tsconfig.summary.json
    tsc -p tsconfig.tasks.json
    cp -R compiled/. "$out/lib/slack-ai-integration/"
    cp -R browser/. "$out/lib/slack-ai-integration/"
    makeWrapper ${lib.getExe nodejs} "$out/bin/slack-ai-integration" \
      --add-flags "$out/lib/slack-ai-integration/start.mjs"
  ''
