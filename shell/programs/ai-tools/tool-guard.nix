{
  programs.ai-agents.toolGuard.system-temp-paths = {
    matcher = ".";
    approvalToken = "ALLOW_SYSTEM_TEMP";
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
    reason = "Temporary files go in <git worktree root>/.tmp/<session>/ (managing-temp-files skill). The per-session scratchpad directory in the system prompt is not an exception.";
  };
}
