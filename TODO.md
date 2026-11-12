# TODO

## Workarounds

Upstream status is unchecked; remove only when the pinned version no longer needs the workaround.

- [ ] Amber dependencies — [dev shell](flake/development.nix); remove when nixpkgs supplies pkg-config and libgit2.
- [ ] tmux popup flicker — [patch](overlays/patches/tmux-3.7c-popup-flicker.patch); remove when pinned tmux includes the backported fixes.
- [ ] yabai macOS 27 support — [patch](pkgs/darwin/yabai/patches/macos-27.patch); remove when upstream supports the host OS.
- [ ] yabai IPC hang — [patch](pkgs/darwin/yabai/patches/sa-response-deadline.patch); remove when upstream bounds IPC waits safely.
- [ ] yabai fullscreen hang — [patch](pkgs/darwin/yabai/patches/fullscreen-transition-waits.patch); remove when upstream bounds transition waits.
- [ ] yabai AX geometry errors — [patch](pkgs/darwin/yabai/patches/ax-geometry-errors.patch); remove when failed reads preserve cached state.
- [ ] yabai response EOF hang — [patch](pkgs/darwin/yabai/patches/response-shutdown.patch); remove when inherited descriptors no longer delay responses.
- [ ] yabai mouse-drop capture — [patch](pkgs/darwin/yabai/patches/mouse-drop-warp-frame-capture.patch); remove when upstream fixes empty-source Space capture.
- [ ] Seamtype number composition — [patch](pkgs/darwin/seamtype/patches/number-composition.patch); remove when upstream fixes numeric-prefix conversion and reentry.
- [ ] Seamtype binary download — [package](pkgs/darwin/seamtype/default.nix); remove when SwiftPM no longer needs the offline binary-target substitution.
- [ ] r2dec API compatibility — [package](pkgs/radare2/r2dec/default.nix); remove when r2dec supports the selected radare2 API.
- [ ] rea bundled dependency links — [override](pkgs/mcp/rea/dream2nix.nix); remove when pinned dream2nix installs bundled dependencies without build-directory symlinks.
- [ ] tupimage tmux image IDs — [patch](portable/vim/nix/terminal-images/shared-tmux-image-ids.patch); remove when upstream safely shares IDs per server.
- [ ] Pi 1.5.0 adjustments — [runtime](portable/pi/nix/runtime.nix); remove unused SDK/declaration fixes once no supported version needs them.

## Investigate

- [ ] Ghidra launcher — [overlay](overlays/patches.nix); establish why the original launcher needs replacing.
- [ ] anyio disabled checks — [overlay](overlays/test-ignores.nix); identify the Darwin test failure and whether it persists.
- [ ] pre-commit disabled checks / DOTNET_ROOT — [dev shell](flake/development.nix); establish why each override remains necessary.
- [ ] Stable package substitutions — [overlay](overlays/stable.nix); check whether the main pinned packages still fail.
- [ ] Linux swift-format dummy — [overlay](overlays/patches.nix); establish the failure and actual consumers.
- [ ] Whisper system llama override — [package](pkgs/ai-tools/whisper-local/default.nix); establish why bundled llama remains necessary.
- [ ] Python bootstrap overrides — [dream2nix](libs/dream2nix/python.nix); distinguish temporary fixes from required sandbox packaging.
- [ ] npm integrity completion — [shared](libs/dream2nix/npm.nix), [Pi](portable/pi/nix/npm.nix); check whether affected locks still need both workarounds.
