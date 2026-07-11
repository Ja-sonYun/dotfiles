{ lib, writers }:

(writers.writePython3Bin "notifycmd" { } (builtins.readFile ./notifycmd.py)).overrideAttrs {
  meta = {
    description = "Send macOS notifications from JSON payloads";
    mainProgram = "notifycmd";
    platforms = lib.platforms.darwin;
  };
}
