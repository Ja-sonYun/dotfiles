{
  Any.command = "send-keys";
  "C-h".command = "if-shell -F '#{==:#{pane_current_command},vim}' 'send-keys C-h' 'select-pane -L'";
  "C-j".command = "if-shell -F '#{==:#{pane_current_command},vim}' 'send-keys C-j' 'select-pane -D'";
  "C-k".command = "if-shell -F '#{==:#{pane_current_command},vim}' 'send-keys C-k' 'select-pane -U'";
  "C-l".command = "if-shell -F '#{==:#{pane_current_command},vim}' 'send-keys C-l' 'select-pane -R'";
  "S-left".command = "select-pane -L";
  "S-down".command = "select-pane -D";
  "S-up".command = "select-pane -U";
  "S-right".command = "select-pane -R";
  F7.command = "if-shell -F '#{==:#{pane_current_command},node}' 'send-keys -H 1b 5b 31 33 3b 32 75' 'send-keys Enter'";
  F8.command = "if-shell -F '#{==:#{pane_current_command},node}' 'send-keys -H 1b 5b 31 33 3b 35 75' 'send-keys Enter'";
  F1.command = "set -gq @nop 1";
  F2.command = "set -gq @nop 1";
  F3.command = "set -gq @nop 1";
  F4.command = "set -gq @nop 1";
  F5.command = "set -gq @nop 1";
  F6.command = "set -gq @nop 1";
  F9.command = "set -gq @nop 1";
  F10.command = "set -gq @nop 1";
  F11.command = "set -gq @nop 1";
  F12.command = "set -gq @nop 1";
  "C-d".script = ''
    if tmux show-environment TMUX_REMAP_CTRL_D >/dev/null 2>&1; then
      tmux send-keys "$(tmux show-environment TMUX_REMAP_CTRL_D | cut -d= -f2-)"
    else
      tmux send-keys C-d
    fi
  '';
  menuCtrlC = {
    key = "C-c";
    cases = [
      {
        whenEnv = [ "CTRL_C_AS_CLOSE" ];
        command = "detach";
      }
      { command = "send-keys C-c"; }
    ];
  };
}
