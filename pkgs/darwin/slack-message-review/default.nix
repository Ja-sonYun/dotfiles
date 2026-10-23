{
  lib,
  runCommand,
  makeWrapper,
  nodejs,
}:
runCommand "slack-message-review"
  {
    nativeBuildInputs = [ makeWrapper ];
    meta = {
      platforms = lib.platforms.darwin;
      mainProgram = "slack-message-review";
    };
  }
  ''
    mkdir -p "$out/bin" "$out/lib/slack-message-review"
    cp ${./start.mjs} "$out/lib/slack-message-review/start.mjs"
    cp ${./review.mjs} "$out/lib/slack-message-review/review.mjs"
    cp ${./classify.mjs} "$out/lib/slack-message-review/classify.mjs"
    cp ${./process.mjs} "$out/lib/slack-message-review/process.mjs"
    cp ${./hook.js} "$out/lib/slack-message-review/hook.js"
    cp ${./draft.js} "$out/lib/slack-message-review/draft.js"
    makeWrapper ${lib.getExe nodejs} "$out/bin/slack-message-review" \
      --add-flags "$out/lib/slack-message-review/start.mjs"
  ''
