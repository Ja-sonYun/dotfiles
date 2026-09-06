{
  programs.ai-agents.toolGuard.system-temp-paths = {
    matcher = ".";
    approvalToken = "ALLOW_SYSTEM_TEMP";
    onBlock = "revise-input";
    inputFields = [
      "command"
      "file_path"
      "notebook_path"
      "out_dir"
      "path"
    ];
    inputPatterns = [
      "(^|[^A-Za-z0-9._-])/(private/)?tmp(/|$)"
      "(^|[^A-Za-z0-9._-])/(private/)?var/folders/"
      "\\$\\{?TMPDIR"
      "(^|[;|&(]|\\$\\()\\s*mktemp\\b"
      "(^|[^A-Za-z0-9._-])/(?![^ ]*/\\.tmp/)([^ ]*/)?scratchpad(/|$)"
    ];
    reason = ''
      The tool input matched a restricted temporary-path pattern; this does not prove
      that a system temporary file would be created. Put temporary files under
      <git worktree root>/.tmp/<session>/ using absolute paths (managing-temp-files skill).
      The per-session scratchpad directory in the system prompt is not an exception.
      Correct actual temporary-file destinations before retrying; setting TMPDIR alone
      does not change explicit destinations. Do not request ALLOW_SYSTEM_TEMP unless
      the user explicitly asks for a system temporary-path exception.
      If the match is an existing code or documentation string, report a possible
      false positive without claiming an actual write or changing that string merely
      to satisfy the guard.
    '';
  };
}
