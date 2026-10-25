(() => {
  const tokenPattern = /⟦SLACK_ELEMENT_[^⟧]*⟧/g;

  function parts(text) {
    return text.split(/(⟦SLACK_ELEMENT_[^⟧]*⟧)/g).filter(Boolean);
  }

  function valid(elements, text) {
    if (typeof text !== "string" || !text.trim()) return false;
    const tokens = text.match(tokenPattern) ?? [];
    return (
      tokens.length === elements.length &&
      elements.every(({ token }, index) => token === tokens[index])
    );
  }

  function units(ops) {
    return ops.flatMap((op) =>
      (typeof op.insert === "string" ? [...op.insert] : [op.insert]).map(
        (insert) => ({ insert, attributes: op.attributes ?? {} }),
      ),
    );
  }

  function capture(ops) {
    const source = units(ops);
    const elements = [];
    const id = crypto.randomUUID();
    let text = "";
    for (const op of ops) {
      if (
        typeof op.insert !== "string" ||
        op.attributes?.slackmention ||
        op.attributes?.link
      ) {
        const token = `⟦SLACK_ELEMENT_${id}_${elements.length}⟧`;
        elements.push({
          token,
          label:
            typeof op.insert === "string" ? op.insert : "[Embedded element]",
          href: op.attributes?.link,
          units: units([op]),
        });
        text += token;
      } else {
        text += op.insert;
      }
    }
    if (source.at(-1)?.insert !== "\n" || !text.endsWith("\n")) {
      throw new Error("Slack draft has no editable final newline.");
    }
    return { source, elements, text: text.slice(0, -1) };
  }

  function diff(before, after) {
    let prefix = 0;
    while (
      prefix < before.length &&
      prefix < after.length &&
      before[prefix] === after[prefix]
    )
      prefix++;
    let suffix = 0;
    while (
      suffix < before.length - prefix &&
      suffix < after.length - prefix &&
      before[before.length - suffix - 1] === after[after.length - suffix - 1]
    )
      suffix++;
    const a = before.slice(prefix, before.length - suffix);
    const b = after.slice(prefix, after.length - suffix);
    const result = before.slice(0, prefix).map((text) => ["equal", text]);
    if (a.length * b.length > 1_000_000) {
      throw new Error(
        "The text diff exceeds its calculation limit. Make smaller edits or send the original.",
      );
    } else {
      const rows = Array.from(
        { length: a.length + 1 },
        () => new Uint32Array(b.length + 1),
      );
      for (let i = a.length - 1; i >= 0; i--) {
        for (let j = b.length - 1; j >= 0; j--) {
          rows[i][j] =
            a[i] === b[j]
              ? 1 + rows[i + 1][j + 1]
              : Math.max(rows[i + 1][j], rows[i][j + 1]);
        }
      }
      let i = 0;
      let j = 0;
      while (i < a.length || j < b.length) {
        if (i < a.length && j < b.length && a[i] === b[j]) {
          result.push(["equal", a[i++]]);
          j++;
        } else if (
          i < a.length &&
          (j === b.length || rows[i + 1][j] >= rows[i][j + 1])
        ) {
          result.push(["delete", a[i++]]);
        } else {
          result.push(["insert", b[j++]]);
        }
      }
    }
    return result.concat(
      before.slice(before.length - suffix).map((text) => ["equal", text]),
    );
  }

  function textDiff(before, after) {
    const lines = (text) => text.match(/[^\n]*\n|[^\n]+$/g) ?? [];
    const result = [];
    let removed = "";
    let added = "";
    function flush() {
      result.push(...diff([...removed], [...added]));
      removed = "";
      added = "";
    }
    for (const [kind, text] of diff(lines(before), lines(after))) {
      if (kind === "equal") {
        flush();
        result.push(...[...text].map((char) => ["equal", char]));
      } else if (kind === "delete") removed += text;
      else added += text;
    }
    flush();
    return result;
  }

  function listFormatting(expected, convert) {
    const newlines = expected.filter((unit) => unit.insert === "\n");
    const blocks = [];
    let block = [];
    let line = [];
    let lineIndex = 0;
    let fence;
    for (const unit of expected) {
      if (unit.insert !== "\n") {
        line.push(unit);
        continue;
      }
      const text = line
        .map((item) =>
          typeof item.insert === "string" ? item.insert : "\ufffc",
        )
        .join("");
      let delimiter =
        unit.attributes.blockquote || unit.attributes["code-block"]
          ? null
          : text.match(/^\s*(`{3,}|~{3,})/);
      if (delimiter) {
        const end = [...delimiter[0]].length;
        const start = end - delimiter[1].length;
        if (line.slice(start, end).some((item) => item.attributes.code))
          delimiter = null;
      }
      const fenced = Boolean(fence || delimiter);
      if (delimiter) {
        if (!fence) fence = delimiter[1];
        else if (
          delimiter[1][0] === fence[0] &&
          delimiter[1].length >= fence.length
        )
          fence = undefined;
      }
      const match = text.match(
        /^([ \t]*)(?:([・•])[ \t]*|([-*])[ \t]+|(\d+)[.)][ \t]+)(\S.*)$/u,
      );
      if (
        match &&
        !fenced &&
        !unit.attributes.list &&
        !unit.attributes.blockquote &&
        !unit.attributes["code-block"]
      ) {
        const prefix = [...text.slice(0, text.length - match[5].length)];
        const removed = line.slice(0, prefix.length);
        if (
          removed.some(
            (item) =>
              item.attributes.link ||
              item.attributes.slackmention ||
              item.attributes.code,
          )
        ) {
          if (block.length) blocks.push(block);
          block = [];
        } else {
          const width = [...match[1]].reduce(
            (total, char) => total + (char === "\t" ? 2 : 1),
            0,
          );
          block.push({
            newline: unit,
            lineIndex,
            removed,
            depth: width / 2,
            number: match[4] === undefined ? undefined : Number(match[4]),
          });
        }
      } else {
        if (block.length) blocks.push(block);
        block = [];
      }
      line = [];
      lineIndex++;
    }
    if (block.length) blocks.push(block);
    const items = blocks.flatMap((entries) => {
      // Keep text between native lists from merging their numbering during conversion.
      if (
        newlines[entries[0].lineIndex - 1]?.attributes.list ||
        newlines[entries.at(-1).lineIndex + 1]?.attributes.list
      )
        return [];
      const numbers = [];
      let previousDepth = -1;
      for (const entry of entries) {
        if (
          !Number.isInteger(entry.depth) ||
          entry.depth > 4 ||
          entry.depth > previousDepth + 1
        )
          return [];
        if (entry.number !== undefined) {
          // Slack resets a depth's counter only when descending directly into an ordered item.
          if (entry.depth > previousDepth) numbers[entry.depth] = 0;
          if (entry.number !== (numbers[entry.depth] ?? 0) + 1) return [];
          numbers[entry.depth] = entry.number;
        }
        previousDepth = entry.depth;
      }
      return entries;
    });
    const removed = new Set();
    const attributes = new Map();
    if (!items.length) return { removed, attributes };
    const id = crypto.randomUUID();
    let html = "";
    let tag;
    for (const [index, item] of items.entries()) {
      const nextTag = item.number === undefined ? "ul" : "ol";
      if (tag !== nextTag) {
        if (tag) html += `</${tag}>`;
        html += `<${nextTag}>`;
        tag = nextTag;
      }
      // Request explicit clipboard depth and reject conversions that do not preserve it.
      html += `<li data-stringify-indent="${item.depth}">${id}_${index}</li>`;
    }
    html += `</${tag}>`;
    const converted = convert(html);
    if (!Array.isArray(converted?.ops))
      throw new Error("Slack did not return formatted list contents.");
    let index = 0;
    let label = "";
    for (const unit of units(converted.ops)) {
      if (unit.insert !== "\n") {
        label += unit.insert;
        continue;
      }
      const item = items[index];
      if (
        !item ||
        label !== `${id}_${index}` ||
        unit.attributes.list !==
          (item.number === undefined ? "bullet" : "ordered") ||
        (unit.attributes.indent ?? 0) !== item.depth
      )
        throw new Error("Slack did not preserve the requested list structure.");
      const formatted = {
        ...item.newline.attributes,
        list: unit.attributes.list,
      };
      delete formatted.indent;
      if (unit.attributes.indent) formatted.indent = unit.attributes.indent;
      attributes.set(item.newline, formatted);
      for (const prefixUnit of item.removed) removed.add(prefixUnit);
      index++;
      label = "";
    }
    if (index !== items.length || label)
      throw new Error("Slack returned an incomplete formatted list.");
    return { removed, attributes };
  }

  function patch(draft, text, convert) {
    if (!valid(draft.elements, text))
      throw new Error("Keep protected elements in their original order.");
    const before = draft.text.split(tokenPattern);
    const after = text.split(tokenPattern);
    const operations = [];
    for (let i = 0; i < before.length; i++) {
      operations.push(...textDiff(before[i], after[i]));
      for (const unit of draft.elements[i]?.units ?? [])
        operations.push(["equal", unit.insert]);
    }
    operations.push(["equal", "\n"]);
    const contents = [];
    const expected = [];
    let cursor = 0;
    let replacement;
    function inlineAt(index) {
      const unit = draft.source[index];
      if (
        !unit ||
        typeof unit.insert !== "string" ||
        unit.insert === "\n" ||
        unit.attributes.link ||
        unit.attributes.slackmention
      )
        return undefined;
      return unit.attributes;
    }
    function lineAt(index) {
      return (
        draft.source.slice(index).find((unit) => unit.insert === "\n")
          ?.attributes ?? {}
      );
    }
    function append(op) {
      const last = contents.at(-1);
      if (op.retain && last?.retain) last.retain += op.retain;
      else if (op.delete && last?.delete) last.delete += op.delete;
      else contents.push(op);
    }
    for (const [kind, insert] of operations) {
      if (kind === "equal") {
        const unit = draft.source[cursor++];
        append({
          retain: typeof unit.insert === "string" ? unit.insert.length : 1,
        });
        expected.push(unit);
        replacement = undefined;
      } else if (kind === "delete") {
        replacement ??= { inline: inlineAt(cursor), block: lineAt(cursor) };
        append({ delete: insert.length });
        cursor++;
      } else {
        const attributes =
          insert === "\n"
            ? (replacement?.block ?? lineAt(cursor))
            : (replacement?.inline ??
              inlineAt(cursor - 1) ??
              inlineAt(cursor) ??
              {});
        contents.push({ insert, attributes });
        expected.push({ insert, attributes });
      }
    }
    const formatting = listFormatting(expected, convert);
    if (!formatting.removed.size) return { contents, expected };
    // Use source positions to retain existing elements while deleting list markers.
    const origins = new Map(draft.source.map((unit, index) => [unit, index]));
    contents.length = 0;
    cursor = 0;
    const formatted = [];
    function removeUntil(end) {
      while (cursor < end) {
        const unit = draft.source[cursor++];
        append({
          delete: typeof unit.insert === "string" ? unit.insert.length : 1,
        });
      }
    }
    for (const unit of expected) {
      if (formatting.removed.has(unit)) continue;
      const attributes = formatting.attributes.get(unit) ?? unit.attributes;
      const origin = origins.get(unit);
      if (origin === undefined)
        contents.push({ insert: unit.insert, attributes });
      else {
        removeUntil(origin);
        const changed = {};
        for (const key of new Set([
          ...Object.keys(unit.attributes),
          ...Object.keys(attributes),
        ])) {
          if (unit.attributes[key] !== attributes[key])
            changed[key] = attributes[key] ?? null;
        }
        const retain = typeof unit.insert === "string" ? unit.insert.length : 1;
        if (Object.keys(changed).length)
          contents.push({ retain, attributes: changed });
        else if (contents.at(-1)?.attributes) contents.push({ retain });
        else append({ retain });
        cursor++;
      }
      formatted.push({ insert: unit.insert, attributes });
    }
    removeUntil(draft.source.length);
    return { contents, expected: formatted };
  }

  function matches(ops, expected) {
    const canonical = (value) => {
      if (Array.isArray(value)) return value.map(canonical);
      if (value && typeof value === "object") {
        return Object.fromEntries(
          Object.keys(value)
            .sort()
            .map((key) => [key, canonical(value[key])]),
        );
      }
      return value;
    };
    return (
      JSON.stringify(canonical(units(ops))) ===
      JSON.stringify(canonical(expected))
    );
  }

  return { capture, parts, valid, patch, matches };
})();
