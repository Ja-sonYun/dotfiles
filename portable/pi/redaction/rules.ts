import { readFileSync } from "node:fs";
import { pattern } from "./filter.ts";

export interface RedactionRule {
  kind: string;
  literal?: Buffer;
  regex?: string;
}

export function personalRules(env: NodeJS.ProcessEnv): RedactionRule[] {
  if (!env.PI_REDACTION_RULES_FILE) return [];

  let content: string;
  try {
    content = readFileSync(env.PI_REDACTION_RULES_FILE, "utf8");
  } catch {
    throw new Error("Cannot read redaction rules");
  }
  return content.split("\n").flatMap((raw, index) => {
    const line = raw.replace(/\r$/, "");
    if (!line) return [];
    if (line.startsWith("regex:")) {
      const regex = line.slice(6);
      if (pattern(regex).matcher("").find())
        throw new Error(`Empty-matching redaction rule at line ${index + 1}`);
      return [
        {
          kind: "custom-regex",
          regex,
        },
      ];
    }
    const reference = /^\$\(([A-Za-z_][A-Za-z0-9_]*)\)$/.exec(line);
    const text = line.startsWith("text:")
      ? line.slice(5)
      : reference
        ? (env[reference[1]] ?? "")
        : line;
    const kind = reference
      ? `env-${reference[1].toLowerCase().replaceAll("_", "-")}`
      : "custom-text";
    return text
      ? [
          {
            kind,
            literal: Buffer.from(text),
          },
        ]
      : [];
  });
}

export const commonRules: RedactionRule[] = [
  {
    kind: "token",
    regex: "(?i)\\b(?:Bearer|Basic)[ \\t]+([a-z0-9._~+/=-]+)",
  },
];
