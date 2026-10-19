# Portable Pi

Run on `aarch64-darwin` from this directory:

```sh
nix run path:.
nix run path:.#pi-dev
```

`pi` keeps the normal Pi profile; `pi-dev` uses `~/.pi/agent-dev`.
When the profile has no `settings.json`, the launcher copies `config/defaults.json`'s
settings into the profile. Existing settings, authentication and sessions stay in the profile.
Set `PI_RESOURCE_PACKAGE` to select another resource package for either command.
`config/` owns the common settings, development tools and permission presets.
Both launchers use this configuration without Home Manager.
Dotfiles installs the standalone package and supplies personal inputs through environment
variables. Inherited environment values take precedence over its environment defaults.

Shared inputs are optional. Use absolute paths:

| Environment variable      | Input                                                                    |
| ------------------------- | ------------------------------------------------------------------------ |
| `PI_SKILLS_DIR`           | Recursive skill source directory, passed to native `--skill`.            |
| `PI_AGENTS_DIR`           | Source Markdown agents with YAML frontmatter, interpreted by Pi.         |
| `PI_MCP_CONFIG`           | JSON file containing `mcpServers`, registered through the MCP extension. |
| `PI_CONTEXT_FILE`         | Global AGENTS context file, loaded alongside native project context.     |
| `PI_REDACTION_RULES_FILE` | Personal redaction rule file.                                            |
| `PI_PROVIDERS_CONFIG`     | JSON object mapping custom provider IDs to their configuration.          |
| `PI_PERMISSIONS_CONFIG`   | Main TOML file containing personal policy and rule-file paths.           |

The MCP input accepts native Pi server fields. Stdio servers may also supply
`instructions`; remote servers cannot override instructions. Native profile or
project `mcp.json` entries take precedence over same-name extension registrations.
`PI_MCP_CONFIG` and `PI_CONTEXT_FILE` read failures report extension loading errors.

Provider credentials use native Pi authentication or inherited provider environment
variables. `PI_PROVIDERS_CONFIG` adds custom providers; without it, standalone Pi
registers none. The `lmp` entry inherits metadata from `config/defaults.json` and needs
`baseUrl` (without `/v1`) and `apiKey`. Both accept a string or `{ "_secret": "/absolute/file" }`.
Other providers supply the full [provider definition](extensions/providers/index.ts).
Unreadable provider configuration or credential files report extension loading errors.

Development tools are supplied by `config/default.nix`; the launcher also supplies
Git, ripgrep and shfmt. Project agents retain precedence over user agents.

`PI_AGENTS_DIR` replaces the profile's user-agent directory. Source filenames must
match their `name`, and each source needs a `description`. `model` accepts `inherit`
or the `xhigh`, `high`, `middle`, `low` tiers; all tiers currently use the model and
thinking level in `config/defaults.json`. `permissionMode` accepts `default` or
`plan`. Optional `tools` accepts MCP server wildcards resolved using `PI_MCP_CONFIG`.
Pi interprets these sources in memory; native profile and project agents keep their
native format. Invalid source agents reject discovery.

The permissions TOML uses `[policy.presets]`, `[[policy.commands.rules]]`,
`[[policy.files.rules]]`, `[policy.mcp.<server>]` and `[policy.mcp_readonly_tools]`.
The optional `[rules]` table points to separate files relative to the main TOML:

```toml
[rules]
code = "rules/code.toml"
tool = "rules/tool.toml"
task = "rules/task.toml"
```

Each rule file uses `[<id>]` tables with `why`, `message` and exactly one
`check.intent` or `check.regex`. Use TOML multiline literal strings for
long criteria and regexes. Rule IDs are unique across all groups. `[summaries]`
can select a provider and model; omitted settings use the public defaults.

Pi reads and validates the TOML at runtime through its evaluator's Python `tomllib`.
Each permission check reads the main file and referenced rule files once. Changes
to their paths or contents reset session approvals. Invalid or unreadable
configuration blocks tool execution; a plan child also disables its active tools.
Without `PI_PERMISSIONS_CONFIG`, Pi uses the public defaults and no personal rules.

Standalone Pi includes a default permission policy. Intent checks use `TYPESAFE_API_KEY`.
When the key is missing, intent checks are unavailable; calls requiring those checks
need approval for each execution. Approval requires an interactive UI.

The AI can call the native `rules_check` tool with task text. Tool and code checks
run on tool calls. Violations, uncertain findings and evaluation failures return
a request ID when the evaluator can capture the request state. The AI calls
`rules_request_approval` with that ID to open Pi's approval UI. Choose **Allow once**,
then retry the same tool call or task text. Task approval reports `user_approved`;
it does not authorize execution. `completed` means the check finished, so inspect
its findings before continuing.

Each exception belongs to the requesting agent, user request, policy, rules and
exact call or task text. Edit exceptions also bind the target paths, file contents
and modes. Approval and retry recheck that state; a successful retry consumes the
exception once. Context resets clear pending exceptions. Subagents use the parent
UI through their permission channel. Cancellation, missing UI or changed state
does not grant an exception. Explicit policy denials remain blocked.

Without `PI_REDACTION_RULES_FILE`, masking uses built-in rules only.
Bash output is withheld until masking succeeds. More than 16 MiB cancels the command
and discards its output. Masking failures, including the 10-second limit, also withhold output.

The built-in detector corpus and compressed word list come from
[betterleaks v1.9.0](https://github.com/betterleaks/betterleaks/tree/v1.9.0).
The upstream license is in `redaction/LICENSE.betterleaks`.
