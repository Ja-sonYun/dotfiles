# pi-permission-checker

Global Pi extension that enforces Claude Code-style permission rules.

## Config

Edit `config.json`:

```json
{
  "debug": false,
  "defaultMode": "ask",
  "permissions": {
    "allow": ["read", "bash(git status *)"],
    "ask": ["bash", "edit(src/**)"],
    "deny": [
      "Path(**/.env*)",
      "ArgRegex((^|/)\\.env($|\\..*))",
      "bash(rm -rf *)"
    ]
  }
}
```

Set `debug` to `true` to show a one-time notification for each permission check with the tool, final decision, policy rule, access subject, parsed bash command units, argv, and extracted path candidates.

Rules use:

- `tool` — match all calls to a tool, e.g. `read`
- `tool(glob)` — match a tool specifier, e.g. `bash(git status *)` or `edit(src/**)`
- `bash(argv:tokens...)` — match parsed bash argv tokens instead of raw command text
- `Path(glob)` — cross-cutting path rule for file tools and command-analyzer path candidates
- `ArgRegex(regex)` — deny-only regex matched against bash argv tokens

For `bash(argv:...)`:

- `*` matches one argv token
- `**` matches zero or more argv tokens
- `*` inside a token works as a glob, e.g. `-i*` matches `-i` and `-i.bak`

`ArgRegex(...)` is only valid in `deny`. It is a fallback for dangerous argv strings when a command-specific analyzer does not know whether an argument is a path.

Examples:

```json
{
  "allow": ["bash(*)"],
  "deny": [
    "bash(argv:sed ** -i* **)",
    "bash(argv:sed ** --in-place* **)",
    "bash(argv:git push **)"
  ]
}
```

Command-specific analyzers live one-per-file under `src/commands/defs/` behind a small `CommandAnalyzer` interface. Common shapes are declared with builders from `src/commands/helpers.ts` (`readCmd`, `writeCmd`, `srcDestCmd`, `wrapperCmd`, `shellExecCmd`, `programFirstCmd`, `interpreterCmd`, `specThenWriteCmd`); idiosyncratic commands (`sed`, `find`, `tar`, …) supply a bespoke `analyze`. To add a command, drop a file in `defs/` and regenerate the `defs/index.ts` barrel. Unknown command argv is not guessed as a path; add a def when argv path semantics are known. For example, the `sed` analyzer marks in-place edit targets as `edit` paths, while `cat` marks file operands as `read` paths.

Commands that run code which can't be statically analyzed (`python -c`, `perl -e`, `eval`, `make`, `source`) are marked **opaque**: a matching `allow` (or `defaultMode: allow`) is upgraded to `ask` so the user always confirms. `deny` rules and session decisions still take precedence. A bash command whose file operands still contain unresolved shell metacharacters — a glob or expansion such as `cat *.env` or `cat $SECRET` — is treated the same way (opaque → ask), because the concrete target can't be matched against `Path(...)` deny rules. A known limitation: relative paths after a `cd` in the same command (`cd /etc && cat passwd`) are resolved against the original cwd.

Search tools get an additional conservative filter: recursive `grep`, `find`, and `rg`/ripgrep searches ask for confirmation when they may include a denied `Path(...)` pattern, even if the bare tool or command would otherwise be allowed. Denied search-filter responses include exclusion-option examples for the agent to retry safely. Explicit single-file `grep` still follows normal path/tool rules.

Decision order:

1. deny rules
2. session approvals
3. allow rules
4. ask rules
5. `defaultMode`

When `Allow for this session` is selected, an approval is stored as a Pi custom session entry (`permission-checker-approval`). It survives `/reload` and session resume because it is part of the session file. No rule is generated or suggested. For known read/edit/write path requests, the prompt can approve only that file, all files under the parent directory, or all files under the file's git root. Deny rules still win over every session approval.

For `bash`, the extension requires `tree-sitter-bash`. If parsing fails, the extension blocks the call and asks the model to rewrite the command up to 3 times. After repeated parse failures, unparsed bash commands stay blocked.

## Commands

- `/permission-checker show`
- `/permission-checker path`
- `/permission-checker reload`
- `/permission-checker approvals`

## Tests

```bash
cd ~/dotfiles/shell/programs/pi/dev-extensions/pi-permission-checker
npm run check
npm test
```

The e2e tests cover recursive bash command analyzers (`xargs`, `find -exec`, `sh -c`, `sed -i`), known-path command handling, `ArgRegex`, evaluator deny decisions, realpath/symlink path matching, search-tool filters, scoped session approvals, and session approval restore.

## Optional AST dependencies

This directory includes a small flake for Node.js:

```bash
cd ~/dotfiles/shell/programs/pi/dev-extensions/pi-permission-checker
nix develop -c npm install
```

Without `node_modules`, bash parsing fails closed: the model gets repair feedback first, then the command stays blocked after repeated failures. Install dependencies for AST-level bash checks.
