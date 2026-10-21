{ hasTag, ... }:
{
  programs.tmux.extensions.mcp = {
    enable = hasTag "ai";
    allowedSessionPatterns = [
      "^(main|popup)$"
      "^_popup_[^_]+_(?:(?:git_)?root_)?subshell_.+$"
    ];
    capture = {
      defaultLines = 200;
      maxLines = 5000;
      maxOutputBytes = 65536;
    };
    sendKeys.enable = true;
    redaction = {
      timeoutSeconds = 10;
      maxInputBytes = 16777216;
    };
    instructions = ''
      main contains regular project windows. popup is the shared shell popup.
      Project shell popups use the logical name subshell and are scoped to a
      .root or Git root. Agent popups and All Agents are outside the allowed scope.
      Inspect pane working directories to choose the current project's shell.
      The user's tmux prefix is Ctrl+q; never send it through this server.
      Ctrl+q t opens the user's pane picker and Ctrl+q k opens the tmux menu.
      Ctrl+h/j/k/l normally navigate tmux panes or Vim. Those client bindings,
      popup-close shortcuts, and other tmux remappings do not apply to direct
      pane input through send_keys. Send only input intended for the pane program.
    '';
  };
}
