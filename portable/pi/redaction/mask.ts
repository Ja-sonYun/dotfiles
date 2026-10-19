import { detect } from "./detector.ts";
import { pattern } from "./filter.ts";
import { commonRules, personalRules, type RedactionRule } from "./rules.ts";

interface Span {
  start: number;
  end: number;
  kind: string;
  priority: number;
}

export function mask(input: Buffer, env: NodeJS.ProcessEnv): Buffer {
  const spans: Span[] = [];
  const rules: RedactionRule[] = [
    ...personalRules(env),
    ...detect(input),
    ...commonRules,
  ];
  for (const [priority, rule] of rules.entries()) {
    if (rule.regex !== undefined) {
      const matcher = pattern(rule.regex).matcher(input);
      const group = matcher.groupCount() ? 1 : 0;
      while (matcher.find()) {
        const start = matcher.start(group);
        const end = matcher.end(group);
        if (start >= 0 && end > start)
          spans.push({
            start,
            end,
            kind: rule.kind,
            priority,
          });
      }
    } else if (rule.literal?.length) {
      let offset = 0;
      while (offset < input.length) {
        const start = input.indexOf(rule.literal, offset);
        if (start < 0) break;
        spans.push({
          start,
          end: start + rule.literal.length,
          kind: rule.kind,
          priority,
        });
        offset = start + 1;
      }
    }
  }

  spans.sort((a, b) => a.start - b.start);

  const chunks: Buffer[] = [];
  let size = 0;
  const append = (chunk: Buffer) => {
    size += chunk.length;
    if (size > 32 * 1024 * 1024)
      throw new Error("Redacted output limit exceeded");
    chunks.push(chunk);
  };

  let previous = 0;
  for (let index = 0; index < spans.length;) {
    let best = spans[index++];
    const start = best.start;
    let end = best.end;
    while (index < spans.length && spans[index].start < end) {
      const next = spans[index++];
      end = Math.max(end, next.end);
      const length = next.end - next.start;
      const bestLength = best.end - best.start;
      if (
        length > bestLength ||
        (length === bestLength && next.priority < best.priority)
      )
        best = next;
    }
    append(input.subarray(previous, start));
    let offset = start;
    for (let cursor = start; cursor <= end; cursor++) {
      if (cursor === end || input[cursor] === 0) {
        if (cursor > offset) append(Buffer.from(`[REDACTED:${best.kind}]`));
        if (cursor < end) append(Buffer.from([0]));
        offset = cursor + 1;
      }
    }
    previous = end;
  }
  append(input.subarray(previous));
  return Buffer.concat(chunks, size);
}
