{
  pkgs,
  extraPath ? [ ],
  extraPythonPath ? "",
  ...
}:

let
  inherit (pkgs) lib;

  wrapperArgs = lib.concatStringsSep " \\\n      " (
    lib.optional (extraPath != [ ]) ''--prefix PATH : "${lib.makeBinPath extraPath}"''
    ++ lib.optional (extraPythonPath != "") ''--prefix PYTHONPATH : "${extraPythonPath}"''
  );

  piRoot = "$NODE_PATH/lib/node_modules/@earendil-works/pi-coding-agent";

  # pi exposes no extension hooks for message/theme rendering, so patch the bundle.
  patches = [
    # tmux extended-keys warning is a false positive with our F7/F8 csi-u setup.
    {
      file = "dist/modes/interactive/interactive-mode.js";
      from = "this.checkTmuxKeyboardSetup().then";
      to = "Promise.resolve(undefined).then";
    }
    {
      file = "dist/modes/interactive/interactive-mode.js";
      from = "if (textContent) {\n                    if (this.chatContainer.children.length > 0) {";
      to = "if (textContent) {\n                    if (this.chatContainer.children.length >= 0) {";
    }
    {
      file = "dist/modes/interactive/theme/theme.js";
      from = ''return `''${ansi}''${text}\x1b[49m`;'';
      to = ''return color === "userMessageBg" ? "\x1b[49m" + text : ["customMessageBg","toolPendingBg","toolSuccessBg","toolErrorBg"].includes(color) && text.length > 1 ? (text.trim() === "" ? "\x1b[49m" + text : this.fg({toolSuccessBg:"success",toolErrorBg:"error",toolPendingBg:"warning",customMessageBg:"accent"}[color], "┃") + text.slice(0, -1)) : `''${ansi}''${text}\x1b[49m`;'';
    }
    {
      file = "dist/modes/interactive/components/assistant-message.js";
      from = "const lines = super.render(width);";
      to = ''const __r = super.render(width - 1); const lines = __r.map((__l, __i) => __i === 0 && __l.trim() === "" ? __l : theme.fg("accent", "┃") + __l);'';
    }
    {
      file = "dist/modes/interactive/components/user-message.js";
      from = ''new Box(this.outputPad, 1, (content) => theme.bg("userMessageBg", content))'';
      to = ''new Box(this.outputPad, 0, (content) => theme.bg("userMessageBg", content))'';
    }
    # Default thinking text is too dark to read.
    {
      file = "dist/modes/interactive/theme/dark.json";
      from = ''"thinkingText": "gray"'';
      to = ''"thinkingText": "#b0b0b0"'';
    }
    # Drop tool block vertical padding so the bar has no empty cap lines.
    {
      file = "dist/modes/interactive/components/tool-execution.js";
      from = ''new Box(1, 1, (text) => theme.bg("toolPendingBg", text))'';
      to = ''new Box(1, 0, (text) => theme.bg("toolPendingBg", text))'';
    }
    {
      file = "dist/modes/interactive/components/tool-execution.js";
      from = ''new Text("", 1, 1, (text) => theme.bg("toolPendingBg", text))'';
      to = ''new Text("", 1, 0, (text) => theme.bg("toolPendingBg", text))'';
    }
  ];

  applyPatches = lib.concatMapStringsSep "\n" (
    p:
    ''substituteInPlace "${piRoot}/${p.file}" --replace-fail ${lib.escapeShellArg p.from} ${lib.escapeShellArg p.to}''
  ) patches;
in
pkgs.lib.mkPackageDerivation {
  inherit pkgs;
  hashKey = "pi";
  packageManager = "npm";
  packageName = "@earendil-works/pi-coding-agent";
  packageVersion = "0.81.1";
  name = "pi";
  exposedBinaries = [
    "pi"
  ];
  postInstall =
    applyPatches
    + "\n"
    + lib.optionalString (extraPath != [ ] || extraPythonPath != "") ''
      rm -f $out/bin/pi
      makeWrapper "$NODE_PATH/bin/pi" "$out/bin/pi" \
        ${wrapperArgs}
    '';
}
