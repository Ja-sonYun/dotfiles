{ pkgs, ... }:
{
  programs.ghostty = {
    enable = true;
    enableZshIntegration = true;

    # Use brew to install ghostty on macOS
    package = if pkgs.stdenv.isDarwin then null else pkgs.ghostty;

    settings = {
      # Terminal identity
      term = "xterm-256color";

      # Font
      font-family = "BigBlue_TerminalPlus Nerd Font";
      font-codepoint-map = [
        "U+3040-U+309F=Hiragino Sans"
        "U+30A0-U+30FF=Hiragino Sans"
        "U+4E00-U+9FFF=Hiragino Sans"
        "U+3400-U+4DBF=Hiragino Sans"
        "U+FF00-U+FFEF=Hiragino Sans"
      ];

      font-family-bold = "BigBlue_TerminalPlus Nerd Font";
      font-family-italic = "BigBlue_TerminalPlus Nerd Font";
      font-family-bold-italic = "BigBlue_TerminalPlus Nerd Font";
      font-style = "Book";
      font-size = 11;

      adjust-cursor-thickness = "200%";

      font-feature = [
        "-calt"
        "-dlig"
      ];

      font-thicken = true;
      font-synthetic-style = false;
      minimum-contrast = 1;
      selection-invert-fg-bg = false;

      # Colors
      background = "000000";
      foreground = "ffffff";
      cursor-color = "ffffff";
      cursor-text = "F81CE5";
      palette = [
        "0=#000000"
        "1=#fe0100"
        "2=#33ff00"
        "3=#feff00"
        "4=#0066ff"
        "5=#cc00ff"
        "6=#00ffff"
        "7=#d0d0d0"
        "8=#808080"
        "9=#fe0100"
        "10=#33ff00"
        "11=#feff00"
        "12=#0066ff"
        "13=#cc00ff"
        "14=#00ffff"
        "15=#ffffff"
      ];

      # Window
      background-opacity = 0.70;
      window-padding-x = 10;
      window-padding-y = 10;

      # Title bar
      title = "⎦˚◡˚⎣";
      macos-titlebar-style = "hidden";
      macos-option-as-alt = true;

      # Keybinds
      keybind = [
        "clear"
        "cmd+c=copy_to_clipboard"
        "cmd+v=paste_from_clipboard"
        "cmd+a=select_all"
        "cmd+q=quit"
        "cmd+w=close_window"
      ];
    };
  };
}
