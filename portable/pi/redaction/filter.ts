import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { gunzipSync } from "node:zlib";
import type { RE2JS as Pattern } from "re2js";

// Resolve mutable-source dependencies from the Nix wrapper's NODE_PATH.
const require = createRequire(import.meta.url);
const { getEncoding } = require("js-tiktoken") as typeof import("js-tiktoken");
const { RE2JS } = require("re2js") as typeof import("re2js");

const patterns = new Map<string, Pattern>();

export function pattern(source: string): Pattern {
  let compiled = patterns.get(source);
  if (!compiled) {
    compiled = RE2JS.compile(source);
    patterns.set(source, compiled);
  }
  return compiled;
}

let tokenizer: ReturnType<typeof getEncoding> | undefined;
let words: Set<string> | undefined;

function tokenRatio(secret: string): number {
  if (Buffer.byteLength(secret) < 20) secret = secret.replace(/[\r\n]/g, "");

  tokenizer ??= getEncoding("cl100k_base");
  const tokens = tokenizer.encode(secret, [], []);
  return tokens.length ? Buffer.byteLength(secret) / tokens.length : 0;
}

function hasWord(secret: string, minimum: number): boolean {
  words ??= new Set(
    gunzipSync(readFileSync(new URL("./words.txt.gz", import.meta.url)))
      .toString("utf8")
      .split("\n"),
  );

  const value = secret.toLowerCase();
  for (let start = 0; start <= value.length - minimum; start++) {
    for (let end = start + minimum; end <= value.length; end++) {
      if (words.has(value.slice(start, end))) return true;
    }
  }
  return false;
}

function entropy(secret: string): number {
  const bytes = Buffer.from(secret);
  const counts = new Uint32Array(256);
  for (const byte of bytes) counts[byte]++;

  let result = 0;
  for (const count of counts) {
    if (count) {
      const p = count / bytes.length;
      result -= p * Math.log2(p);
    }
  }
  return result;
}

// Evaluate only the expression dialect used by the pinned default rule corpus.
// https://github.com/betterleaks/betterleaks/tree/v1.9.0/internal/exprruntime
type Scope = Record<string, any>;
type Expression = (scope: Scope) => any;
const functions: Record<string, (...args: any[]) => any> = {
  entropy,
  matchesAny: (value: string, sources: string[]) =>
    sources.some((source) => pattern(source).matcher(value).find()),
  containsAny: (value: string, terms: string[]) =>
    terms.some((term) => value.toLowerCase().includes(term)),
  findMatch: (value: string, source: string) => {
    const matcher = pattern(source).matcher(value);
    return matcher.find() ? matcher.group() : "";
  },
  tokenRatio,
  failsTokenEfficiency: (value: string) => {
    const analyzed =
      Buffer.byteLength(value) < 20 ? value.replace(/[\r\n]/g, "") : value;
    const ratio = tokenRatio(analyzed);
    return (
      hasWord(analyzed, 5) ||
      ratio >=
        (Buffer.byteLength(analyzed) < 12 && hasWord(analyzed, 4) ? 2.1 : 2.5)
    );
  },
  setConfidence: (value: string) => value,
  len: (value: string | unknown[]) =>
    typeof value === "string" ? Buffer.byteLength(value) : value.length,
  split: (value: string, separator: string) => value.split(separator),
  join: (values: string[], separator: string) => values.join(separator),
  max: Math.max,
  min: Math.min,
};

export function compileFilter(source: string): Expression {
  const tokens: {
    text: string;
    value?: string;
  }[] = [];
  const token =
    /\s+|\/\/[^\n]*|`[^`]*`|"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|\d+(?:\.\d+)?|[A-Za-z_][\w.]*|&&|\|\||==|!=|<=|>=|[()[\],:;?=+!<>-]/gy;
  let offset = 0;
  while (offset < source.length) {
    token.lastIndex = offset;
    const match = token.exec(source);
    if (!match) throw new Error("Unsupported detector filter syntax");

    offset = token.lastIndex;
    const text = match[0];
    if (/^\s|^\/\//.test(text)) continue;

    if (text.startsWith("`")) {
      tokens.push({
        text: "string",
        value: text.slice(1, -1),
      });
    } else if (text.startsWith('"')) {
      tokens.push({
        text: "string",
        value: JSON.parse(text),
      });
    } else if (text.startsWith("'")) {
      tokens.push({
        text: "string",
        value: text.slice(1, -1).replace(/\\'/g, "'"),
      });
    } else {
      tokens.push({
        text,
      });
    }
  }

  let position = 0;
  const peek = () => tokens[position]?.text;
  const take = (expected: string) => {
    if (peek() !== expected) throw new Error("Invalid detector filter");
    position++;
  };
  const precedence: Record<string, number> = {
    "||": 1,
    "&&": 2,
    "==": 3,
    "!=": 3,
    "<": 4,
    ">": 4,
    "<=": 4,
    ">=": 4,
    "+": 5,
    "-": 5,
  };

  const expression = (minimum = 0): Expression => {
    const current = tokens[position++];
    if (!current) throw new Error("Incomplete detector filter");

    let left: Expression;
    if (current.text === "string") {
      left = () => current.value;
    } else if (/^\d/.test(current.text)) {
      left = () => Number(current.text);
    } else if (current.text === "true" || current.text === "false") {
      left = () => current.text === "true";
    } else if (current.text === "!" || current.text === "-") {
      const child = expression(6);
      left =
        current.text === "!"
          ? (scope) => !child(scope)
          : (scope) => -child(scope);
    } else if (current.text === "(") {
      left = expression();
      take(")");
    } else if (current.text === "[") {
      const entries: Expression[] = [];
      while (peek() !== "]") {
        entries.push(expression());
        if (peek() !== ",") break;
        position++;
      }
      take("]");
      left = (scope) => entries.map((entry) => entry(scope));
    } else {
      const name = current.text.replace(/^filter\./, "");
      if (peek() === "(") {
        const call = functions[name];
        if (!call) throw new Error("Unknown detector filter function");
        position++;
        const args: Expression[] = [];
        while (peek() !== ")") {
          args.push(expression());
          if (peek() !== ",") break;
          position++;
        }
        take(")");
        left = (scope) => call(...args.map((arg) => arg(scope)));
      } else {
        left = (scope) =>
          name.split(".").reduce((value, key) => value[key], scope);
      }
    }

    while (peek() === "[") {
      position++;
      const base = left;
      const start = peek() === ":" ? undefined : expression();
      if (peek() === ":") {
        position++;
        const end = peek() === "]" ? undefined : expression();
        left = (scope) => {
          const value = base(scope);
          const from = start?.(scope) ?? 0;
          const to = end?.(scope);
          return typeof value === "string" || Buffer.isBuffer(value)
            ? Buffer.from(value).subarray(from, to).toString("utf8")
            : value.slice(from, to);
        };
      } else {
        left = (scope) => base(scope)[start!(scope)] ?? "";
      }
      take("]");
    }

    while ((precedence[peek()!] ?? -1) >= minimum) {
      const operator = tokens[position++].text;
      const first = left;
      const right = expression(precedence[operator] + 1);
      left = (scope) => {
        const a = first(scope);
        if (operator === "&&") return a && right(scope);
        if (operator === "||") return a || right(scope);

        const b = right(scope);
        switch (operator) {
          case "==":
            return a === b;
          case "!=":
            return a !== b;
          case "<":
            return a < b;
          case ">":
            return a > b;
          case "<=":
            return a <= b;
          case ">=":
            return a >= b;
          case "+":
            return a + b;
          case "-":
            return a - b;
          default:
            throw new Error("Unsupported detector operator");
        }
      };
    }

    if (minimum === 0 && peek() === "?") {
      position++;
      const condition = left;
      const yes = expression();
      take(":");
      const no = expression();
      left = (scope) => (condition(scope) ? yes(scope) : no(scope));
    }
    return left;
  };

  const bindings: {
    name: string;
    value: Expression;
  }[] = [];
  while (peek() === "let") {
    position++;
    const name = tokens[position++].text;
    take("=");
    bindings.push({
      name,
      value: expression(),
    });
    take(";");
  }

  const result = source.trim() ? expression() : () => false;
  if (position !== tokens.length)
    throw new Error("Trailing detector filter syntax");

  return (input) => {
    const scope = { ...input };
    for (const binding of bindings) scope[binding.name] = binding.value(scope);
    return result(scope);
  };
}
