{
  fetchurl,
  ffmpeg,
  lib,
  python3,
  stdenvNoCC,
  whisper-cpp,
}:
let
  whisperModel = fetchurl {
    url = "https://huggingface.co/ggerganov/whisper.cpp/resolve/362722b3fdcd2300b58a8286933ead1c48619667/ggml-large-v3.bin";
    hash = "sha256-ZNGCtEC5jVIDxPm9VBVE2ExgUZbE97hF36EfsjWU0eI=";
  };
  vadModel = fetchurl {
    url = "https://huggingface.co/ggml-org/whisper-vad/resolve/9ffd54a1e1ee413ddf265af9913beaf518d1639b/ggml-silero-v6.2.0.bin";
    hash = "sha256-KqJpt4XutTqCmDogUB3ffB2cSOM6tjpBORrGyff7aYc=";
  };
in
assert lib.versionAtLeast whisper-cpp.version "1.9.2";
stdenvNoCC.mkDerivation {
  pname = "whisper-local";
  version = "1";
  dontUnpack = true;

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/bin" "$out/share/whisper-local"
    substitute ${./whisper.py} "$out/bin/whisper" \
      --replace-fail '@PYTHON@' '${python3}/bin/python3' \
      --replace-fail '@FFMPEG@' '${ffmpeg}/bin/ffmpeg' \
      --replace-fail '@FFPROBE@' '${ffmpeg}/bin/ffprobe' \
      --replace-fail '@WHISPER_CLI@' '${whisper-cpp}/bin/whisper-cli' \
      --replace-fail '@WHISPER_MODEL@' "$out/share/whisper-local/ggml-large-v3.bin" \
      --replace-fail '@VAD_MODEL@' "$out/share/whisper-local/ggml-silero-v6.2.0.bin"
    chmod +x "$out/bin/whisper"
    ln -s ${whisper-cpp}/bin/whisper-cli "$out/bin/whisper-cli"
    ln -s ${whisperModel} "$out/share/whisper-local/ggml-large-v3.bin"
    ln -s ${vadModel} "$out/share/whisper-local/ggml-silero-v6.2.0.bin"

    runHook postInstall
  '';

  meta = {
    description = "Local Whisper large-v3 transcription with meeting track separation";
    homepage = "https://github.com/ggml-org/whisper.cpp";
    license = lib.licenses.mit;
    mainProgram = "whisper";
    platforms = whisper-cpp.meta.platforms;
  };
}
