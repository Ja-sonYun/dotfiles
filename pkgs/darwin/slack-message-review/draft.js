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

  function patch(draft, text) {
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
    return { contents, expected };
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
