import { readFileSync } from "node:fs";
import { compileFilter, pattern } from "./filter.ts";

interface Rule {
  id: string;
  regex?: string;
  filter?: string;
  keywords?: string[];
  secretGroup?: number;
  skipReport?: boolean;
  path?: string;
  specificity?: number;
  components?: {
    id: string;
    optional?: boolean;
    within?: string;
  }[];
}

interface Finding {
  rule: Rule;
  secret: Buffer;
  start: number;
  end: number;
  line: number;
  endLine: number;
  column: number;
  endColumn: number;
  components: Finding[];
}

// Preserve the text-scan branch, including expression filters and component rules.
// https://github.com/betterleaks/betterleaks/blob/v1.9.0/detect/detect.go
const corpus: {
  filter: string;
  rules: Rule[];
} = JSON.parse(
  readFileSync(new URL("./betterleaks.json", import.meta.url), "utf8"),
);
const globalFilter = compileFilter(corpus.filter);
const rules = new Map(corpus.rules.map((rule) => [rule.id, rule]));
const filters = new Map(
  corpus.rules.map((rule) => [rule.id, compileFilter(rule.filter ?? "")]),
);

for (const rule of corpus.rules) {
  if (rule.regex) pattern(rule.regex);
}

export function detect(input: Buffer): { kind: string; literal: Buffer }[] {
  const lower = input.toString("utf8").toLowerCase();
  const cache = new Map<string, Finding[]>();
  const lineStarts = [0];
  for (let index = 0; index < input.length; index++) {
    if (input[index] === 10) lineStarts.push(index + 1);
  }

  const lineAt = (offset: number) => {
    let low = 0;
    let high = lineStarts.length;
    while (low + 1 < high) {
      const middle = (low + high) >>> 1;
      if (lineStarts[middle] <= offset) low = middle;
      else high = middle;
    }
    return low;
  };

  const scan = (rule: Rule): Finding[] => {
    const cached = cache.get(rule.id);
    if (cached) return cached;

    const found: Finding[] = [];
    cache.set(rule.id, found);
    if (!rule.regex || rule.path) return found;

    const matcher = pattern(rule.regex).matcher(input);
    while (matcher.find()) {
      const start = matcher.start();
      let trimmedStart = start;
      let trimmedEnd = matcher.end();
      while (input[trimmedStart] === 10 && trimmedStart < trimmedEnd)
        trimmedStart++;
      while (input[trimmedEnd - 1] === 10 && trimmedEnd > trimmedStart)
        trimmedEnd--;

      const match = input.subarray(trimmedStart, trimmedEnd);
      const end = start + match.length;

      let secret = match;
      const extraction = pattern(rule.regex).matcher(match);
      if (extraction.find() && extraction.groupCount()) {
        let group = rule.secretGroup ?? 0;
        if (!group) {
          for (let index = 1; index <= extraction.groupCount(); index++) {
            if (
              extraction.start(index) >= 0 &&
              extraction.end(index) > extraction.start(index)
            ) {
              group = index;
              break;
            }
          }
        }
        if (group) {
          const from = extraction.start(group);
          const to = extraction.end(group);
          if (from < 0 || to <= from) continue;
          secret = match.subarray(from, to);
        }
      }
      if (!secret.length) continue;

      const line = lineAt(start);
      const endLine = lineAt(Math.max(start, end - 1));
      const lineEnd = input.indexOf(10, end);
      const scope = {
        attributes: {
          path: "",
        },
        finding: {
          secret: secret.toString("utf8"),
          match: match.toString("utf8"),
          line: input
            .subarray(lineStarts[line], lineEnd < 0 ? input.length : lineEnd)
            .toString("utf8"),
          fragment_raw: input,
          match_start_idx: matcher.start(),
          match_end_idx: matcher.end(),
          match_line_start_idx:
            start === 0
              ? 0
              : Math.max(
                  input.lastIndexOf(10, start - 1),
                  input.lastIndexOf(13, start - 1),
                ) + 1,
          match_line_end_idx: (() => {
            const lf = input.indexOf(10, matcher.end());
            const cr = input.indexOf(13, matcher.end());
            return Math.min(
              lf < 0 ? input.length : lf,
              cr < 0 ? input.length : cr,
            );
          })(),
        },
      };

      if (globalFilter(scope) || filters.get(rule.id)!(scope)) continue;

      found.push({
        rule,
        secret,
        start,
        end,
        line,
        endLine,
        column: start - lineStarts[line],
        endColumn: end - lineStarts[endLine],
        components: [],
      });
    }
    return found;
  };

  const nearby = (primary: Finding, candidate: Finding, within = "") => {
    if (!within) return true;
    const lines = /([0-9]+)L/.exec(within);
    const columns = /([0-9]+)C/.exec(within);

    if (lines) {
      const distance = Number(lines[1]);
      if (
        candidate.line < primary.line - distance ||
        candidate.line > primary.endLine + distance
      )
        return false;
      return (
        !columns ||
        primary.line !== primary.endLine ||
        (candidate.column >= Math.max(0, primary.column - Number(columns[1])) &&
          candidate.column < primary.endColumn + Number(columns[1]))
      );
    }
    if (columns)
      return (
        candidate.start >= Math.max(0, primary.start - Number(columns[1])) &&
        candidate.start < primary.end + Number(columns[1])
      );
    throw new Error("Unsupported component window");
  };

  const findings: Finding[] = [];
  const suppressed = (finding: Finding, previous: Finding[]) =>
    previous.some((other) =>
      [other, ...other.components].some(
        (specific) =>
          specific.line === finding.line &&
          specific.rule.id !== finding.rule.id &&
          (specific.rule.specificity ?? 100) >
            (finding.rule.specificity ?? 100) &&
          specific.secret.includes(finding.secret),
      ),
    );

  for (const rule of [...corpus.rules].sort(
    (a, b) => (b.specificity ?? 100) - (a.specificity ?? 100),
  )) {
    if (
      rule.skipReport ||
      (rule.keywords?.length &&
        !rule.keywords.some((word) => lower.includes(word)))
    )
      continue;
    for (const raw of scan(rule)) {
      if (suppressed(raw, findings)) continue;

      const components: Finding[][] = [];
      let complete = true;
      for (const component of rule.components ?? []) {
        const dependency = rules.get(component.id);
        if (!dependency) throw new Error("Missing detector component");
        const matches = scan(dependency).filter((found) =>
          nearby(raw, found, component.within),
        );
        if (!matches.length && !component.optional) complete = false;
        if (matches.length) components.push(matches);
      }
      if (!complete) continue;

      let combinations: Finding[][] = [[]];
      for (const matches of components) {
        const next: Finding[][] = [];
        outer: for (const combination of combinations) {
          for (const match of matches) {
            next.push([...combination, match]);
            if (next.length === 100) break outer;
          }
        }
        combinations = next;
      }

      findings.push({
        ...raw,
        components: [...new Set(combinations.flat())],
      });
    }
  }

  const componentFindings = new Set(
    findings.flatMap((finding) =>
      finding.components.map(
        (component) =>
          `${component.rule.id}:${component.start}:${component.end}`,
      ),
    ),
  );
  const seen = new Set<string>();

  return findings
    .filter(
      (finding) =>
        !componentFindings.has(
          `${finding.rule.id}:${finding.start}:${finding.end}`,
        ) && !suppressed(finding, findings),
    )
    .flatMap((finding) => [finding, ...finding.components])
    .filter((finding) => {
      const key = `${finding.rule.id}\0${finding.secret.toString("base64")}`;
      if (seen.has(key)) return false;

      seen.add(key);
      return true;
    })
    .map((finding) => ({
      kind: finding.rule.id,
      literal: finding.secret,
    }));
}
