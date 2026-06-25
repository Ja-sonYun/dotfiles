// Permission decision engine. Precedence:
//   1. config deny  2. session deny  3. session allow  4. config allow
//   5. config ask   6. defaultMode
// Recursive searches that could touch a denied Path() are upgraded allow -> ask.

import { matchPathGlob, simpleGlobToRegExp, tokenGlobMatch } from "./paths.ts";
import { matchesAllow, matchesDeny } from "./session.ts";
import type { Config, EvalResult, Request, Rule } from "./types.ts";

function ruleSource(rule: Rule): string {
  switch (rule.kind) {
    case "tool":
      return rule.tool;
    case "toolGlob":
      return `${rule.tool}(${rule.glob})`;
    case "bashArgv":
      return `bash(argv:${rule.tokens.join(" ")})`;
    case "path":
      return `Path(${rule.glob})`;
    case "argRegex":
      return `ArgRegex(${rule.source})`;
  }
}

function normalizeCommand(text: string): string {
  return text.trim().replace(/\s+/g, " ");
}

export function ruleMatches(
  rule: Rule,
  req: Request,
  strictBashGlob = false,
): boolean {
  switch (rule.kind) {
    case "tool":
      return req.tool === rule.tool;
    case "toolGlob":
      if (rule.tool !== req.tool) return false;
      if (req.tool === "bash") {
        // A text glob matches the whole command string, so `*` also spans shell operators
        // (`;`, `&&`, `|`) and a redirect could write somewhere the rule author never intended.
        // For ALLOW (strictBashGlob), restrict the match to a single command unit with no
        // write/edit side effects so a prefix-allow can't authorize chained/extra commands;
        // reads stay allowed (deny Path() rules run first and still gate them). For deny/ask
        // the lenient whole-text match is kept — matching more there only denies/asks more.
        if (strictBashGlob) {
          if (req.units.length > 1) return false;
          if (req.accesses.some((a) => a.kind !== "read")) return false;
        }
        return simpleGlobToRegExp(rule.glob).test(
          normalizeCommand(req.commandText ?? ""),
        );
      }
      return req.accesses.some((a) =>
        matchPathGlob(rule.glob, a.path, req.cwd),
      );
    case "bashArgv":
      return req.units.some((u) => tokenGlobMatch(rule.tokens, u.argv));
    case "path":
      return req.accesses.some((a) =>
        matchPathGlob(rule.glob, a.path, req.cwd),
      );
    case "argRegex":
      return req.units.some(
        (u) =>
          u.argv.some((t) => rule.re.test(t)) || rule.re.test(u.argv.join(" ")),
      );
  }
}

function searchFilterReason(config: Config): string {
  const globs = config.denyPathGlobs;
  const list = globs.join(", ");
  const example = globs[0] ?? "**/.env*";
  return (
    `This recursive search may read denied paths (${list}). ` +
    `Re-run while excluding them, e.g. \`rg --glob '!${example}' ...\`, ` +
    `\`grep --exclude-dir=...\`, or \`find ... -not -path '*${example}*'\`.`
  );
}

/** Resolve an allow, upgrading to ask when the command is opaque or a recursive search could hit denied paths. */
function allowOrUpgrade(
  req: Request,
  config: Config,
  matched: string,
): EvalResult {
  if (req.opaque) {
    return {
      decision: "ask",
      reason:
        "This command runs code that can't be statically analyzed for a safety check.",
      matched: "opaque",
    };
  }
  if (req.isSearch && req.searchRecursive && config.denyPathGlobs.length > 0) {
    return {
      decision: "ask",
      reason: searchFilterReason(config),
      matched: "search-filter",
    };
  }
  return { decision: "allow", reason: "", matched };
}

function describeSubject(req: Request): string {
  if (req.commandText)
    return `bash command "${normalizeCommand(req.commandText)}"`;
  if (req.accesses.length)
    return `${req.tool} (${req.accesses.map((a) => `${a.kind} ${a.path}`).join(", ")})`;
  return req.tool;
}

function denyReason(rule: Rule, req: Request): string {
  return `Blocked by permission deny rule ${ruleSource(rule)} for ${describeSubject(req)}.`;
}

export function evaluate(req: Request, config: Config): EvalResult {
  // 1. config deny
  for (const r of config.deny) {
    if (ruleMatches(r, req)) {
      return {
        decision: "deny",
        reason: denyReason(r, req),
        matched: ruleSource(r),
      };
    }
  }
  // 2. session deny
  if (matchesDeny(req)) {
    return {
      decision: "deny",
      reason: "Denied for this session by the user.",
      matched: "session",
    };
  }
  // 3. session allow
  if (matchesAllow(req)) {
    return { decision: "allow", reason: "", matched: "session" };
  }
  // 4. config allow — strict bash-glob matching (single unit, no write side effects)
  for (const r of config.allow) {
    if (ruleMatches(r, req, true))
      return allowOrUpgrade(req, config, ruleSource(r));
  }
  // 5. config ask
  for (const r of config.ask) {
    if (ruleMatches(r, req)) {
      return { decision: "ask", reason: "", matched: ruleSource(r) };
    }
  }
  // 6. default — a default-allow is still subject to the recursive-search filter.
  if (config.defaultMode === "allow")
    return allowOrUpgrade(req, config, "defaultMode");
  return {
    decision: config.defaultMode,
    reason: config.defaultMode === "deny" ? "Denied by default policy." : "",
    matched: "defaultMode",
  };
}

/** First predefined wildcard pattern that matches one of the request's command units. */
export function matchingWildcard(
  config: Config,
  req: Request,
): string[] | undefined {
  if (req.commandText === undefined) return undefined;
  for (const tokens of config.wildcardable) {
    if (req.units.some((u) => tokenGlobMatch(tokens, u.argv))) return tokens;
  }
  return undefined;
}
