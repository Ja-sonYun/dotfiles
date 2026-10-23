{
  lib,
  runCommand,
  makeWrapper,
  nodejs,
}:
runCommand "slack-thread-summary"
  {
    nativeBuildInputs = [ makeWrapper ];
    meta = {
      platforms = lib.platforms.darwin;
      mainProgram = "slack-thread-summary";
    };
  }
  ''
    mkdir -p "$out/bin" "$out/lib/slack-thread-summary"
    cp ${./start.mjs} "$out/lib/slack-thread-summary/start.mjs"
    cp ${./summarize.mjs} "$out/lib/slack-thread-summary/summarize.mjs"
    cp ${./process.mjs} "$out/lib/slack-thread-summary/process.mjs"
    cp ${./hook.js} "$out/lib/slack-thread-summary/hook.js"
    cp ${./timeline.js} "$out/lib/slack-thread-summary/timeline.js"
    cp ${./store.mjs} "$out/lib/slack-thread-summary/store.mjs"
    makeWrapper ${lib.getExe nodejs} "$out/bin/slack-thread-summary" \
      --add-flags "$out/lib/slack-thread-summary/start.mjs"
  ''
