function createTimeline({
  ancestors,
  fiberProps,
  keyFor,
  retrySave,
  deleteCard,
  memberName,
}: TimelineOptions): Timeline {
  function isRecord(value: unknown): value is Record<string, unknown> {
    return typeof value === "object" && value !== null && !Array.isArray(value);
  }
  function isResize(value: unknown): value is ResizeRow {
    return typeof value === "function";
  }
  function errorMessage(error: unknown): string {
    return error instanceof Error ? error.message : String(error);
  }
  const threads = new Map<string, Map<string, StoredCard>>();
  const deleted = new Set<string>();
  const placements = new Map<HTMLElement, Placement>();
  const heights = new Map<
    ResizeRow,
    Map<string, { thread: string; height: number }>
  >();

  function merge(
    thread: ThreadIdentity,
    cards: StoredCard[],
    deletedIds: string[] = [],
  ): void {
    const key = keyFor(thread);
    const entries = threads.get(key) ?? new Map<string, StoredCard>();
    for (const id of deletedIds) {
      deleted.add(`${key}/${id}`);
      entries.delete(id);
    }
    for (const card of cards) {
      if (deleted.has(`${key}/${card.id}`)) continue;
      if (entries.get(card.id)?.saved && !card.saved) continue;
      entries.set(card.id, card);
    }
    threads.set(key, entries);
  }

  function owners(record: SummaryRecord): Set<unknown> {
    const result = new Set<unknown>();
    for (const fiber of ancestors(record.element)) {
      const props = fiberProps(fiber);
      if (
        props?.channelId !== record.thread.channelId ||
        props?.threadTs !== record.thread.threadTs
      )
        continue;
      result.add(fiber);
      if (fiber.alternate) result.add(fiber.alternate);
      if (fiber.stateNode) result.add(fiber.stateNode);
    }
    return result;
  }

  function rowBinding(
    message: HTMLElement,
    ts: string | undefined,
  ): RowBinding | undefined {
    if (!ts) return undefined;
    for (const fiber of ancestors(message)) {
      const props = fiberProps(fiber);
      if (props?.itemKey !== ts || !isResize(props.onHeightChange)) continue;
      const pending: unknown[] = [fiber.child];
      for (let visited = 0; pending.length && visited < 300; visited++) {
        const child = pending.pop();
        if (!isRecord(child)) continue;
        if (
          child.stateNode instanceof HTMLElement &&
          child.stateNode.contains(message)
        ) {
          return {
            row: child.stateNode,
            message,
            resize: props.onHeightChange,
            ts,
          };
        }
        pending.push(child.sibling, child.child);
      }
    }
    return undefined;
  }

  function remove(placement: Placement): void {
    placement.observer.disconnect();
    cancelAnimationFrame(placement.frame);
    placement.host.remove();
    if (placement.row.isConnected && placement.row.style.height === "auto") {
      const height = placement.row.getBoundingClientRect().height;
      if (placement.height)
        placement.row.style.setProperty(
          "height",
          placement.height,
          placement.priority,
        );
      else placement.row.style.removeProperty("height");
      const message = placement.binding.message;
      const current = message.isConnected
        ? rowBinding(message, message.dataset.msgTs)
        : undefined;
      if (current?.row === placement.row) current.resize(current.ts, height);
    }
    placements.delete(placement.row);
  }

  function mount(
    binding: RowBinding,
    thread: ThreadIdentity,
    cards: StoredCard[],
    signature: string,
    names: Record<string, string>,
  ): void {
    const host = document.createElement("div");
    host.style.cssText =
      "display:block;clear:both;padding:8px 16px 8px 48px;box-sizing:border-box";
    const root = host.attachShadow({ mode: "open" });
    for (const name of ["click", "keydown", "keyup"])
      root.addEventListener(name, (event) => event.stopPropagation());
    const style = document.createElement("style");
    style.textContent = `
      :host { color-scheme:light dark; color:light-dark(#1d1c1d,#e8e8e8); font:13px/1.5 system-ui,sans-serif; }
      article { position:relative; margin:0 0 8px; padding:12px; border:1px solid light-dark(#d9d9dc,#555); border-radius:9px; background:light-dark(#fff,#222529); }
      article:last-child { margin-bottom:0; }
      header { display:flex; flex-wrap:wrap; align-items:center; gap:8px; padding-right:28px; }
      header span { color:light-dark(#65666a,#afb2b8); font-size:12px; }
      .content { max-height:320px; overflow:auto; white-space:pre-wrap; overflow-wrap:anywhere; }
      h4 { margin:12px 0 3px; font-size:13px; }
      p, ul { margin:0; }
      ul { padding-left:20px; }
      li + li { margin-top:4px; }
      .mention { color:light-dark(#1264a3,#85c7ff); background:light-dark(#e8f4fa,#183a50); border-radius:3px; padding:0 3px; }
      button { font:inherit; color:inherit; background:transparent; border:1px solid light-dark(#ddd,#555); border-radius:6px; padding:3px 8px; cursor:pointer; }
      button.delete { position:absolute; top:8px; right:8px; width:28px; height:28px; display:grid; place-items:center; padding:5px; border-color:transparent; }
      button.delete:hover { color:light-dark(#a12620,#ffb3aa); background:light-dark(#f8eeee,#472c2b); }
      button:disabled { opacity:.5; cursor:default; }
      button:focus-visible { outline:2px solid #1264a3; outline-offset:2px; }
      .error { color:light-dark(#a12620,#ffb3aa); }
    `;
    root.append(style);
    function node<K extends keyof HTMLElementTagNameMap>(
      tag: K,
      text: string,
      parent: ParentNode,
      className?: string,
    ): HTMLElementTagNameMap[K] {
      const element = document.createElement(tag);
      element.textContent = text;
      if (element instanceof HTMLButtonElement) element.type = "button";
      if (className) element.className = className;
      parent.append(element);
      return element;
    }
    function richText(element: HTMLElement, text: string): void {
      let offset = 0;
      for (const match of text.matchAll(/<@([A-Z0-9]+)(?:\|[^>]+)?>/g)) {
        const id = match[1];
        if (!id) continue;
        element.append(
          document.createTextNode(text.slice(offset, match.index)),
        );
        const mention = node("span", `@${names[id] || id}`, element, "mention");
        mention.title = id;
        offset = match.index + match[0].length;
      }
      element.append(document.createTextNode(text.slice(offset)));
    }
    for (const card of cards) {
      const article = node("article", "", root);
      article.setAttribute("aria-label", "Local AI thread summary");
      const header = node("header", "", article);
      node("strong", "AI Summary", header);
      node(
        "span",
        `${new Date(card.generatedAt).toLocaleString()} · All ${card.count} messages`,
        header,
      );
      const removeButton = node("button", "", header, "delete");
      removeButton.title = "Delete summary";
      removeButton.setAttribute("aria-label", "Delete summary");
      const icon = document.createElementNS(
        "http://www.w3.org/2000/svg",
        "svg",
      );
      icon.setAttribute("viewBox", "0 0 24 24");
      icon.setAttribute("width", "16");
      icon.setAttribute("height", "16");
      icon.setAttribute("fill", "none");
      icon.setAttribute("stroke", "currentColor");
      icon.setAttribute("stroke-width", "1.7");
      icon.setAttribute("aria-hidden", "true");
      const shape = document.createElementNS(
        "http://www.w3.org/2000/svg",
        "path",
      );
      shape.setAttribute(
        "d",
        "M3 6h18M9 6V3h6v3M5 6l1 15h12l1-15M10 10v7M14 10v7",
      );
      icon.append(shape);
      removeButton.append(icon);
      const deleteError = node("div", "", article, "error");
      deleteError.hidden = true;
      deleteError.setAttribute("role", "alert");
      removeButton.onclick = async () => {
        removeButton.disabled = true;
        deleteError.hidden = true;
        try {
          await deleteCard(thread, card.id);
        } catch (failure) {
          deleteError.textContent = errorMessage(failure);
          deleteError.hidden = false;
          removeButton.disabled = false;
        }
      };
      if (!card.saved) {
        const error = node("span", "Not saved", header, "error");
        const retry = node("button", "Retry save", header);
        retry.onclick = async () => {
          retry.disabled = true;
          try {
            await retrySave(thread, card.id);
          } catch (failure) {
            error.textContent = errorMessage(failure);
            retry.disabled = false;
          }
        };
      }
      const content = node("div", "", article, "content");
      node("h4", "Overview", content);
      const overview = node("ul", "", content);
      for (const line of card.summary.overview.split(/\r?\n/)) {
        const point = line.trim().replace(/^(?:[-*•]|\d+[.)])\s+/, "");
        if (point) richText(node("li", "", overview), point);
      }
      for (const [key, title] of [
        ["decisions", "Decisions"],
        ["actions", "Remaining actions"],
      ] as const) {
        node("h4", title, content);
        if (!card.summary[key].length) node("p", "None established", content);
        else {
          const list = node("ul", "", content);
          for (const item of card.summary[key])
            richText(node("li", "", list), item);
        }
      }
    }
    const placement: Placement = {
      row: binding.row,
      binding,
      host,
      signature,
      height: binding.row.style.getPropertyValue("height"),
      priority: binding.row.style.getPropertyPriority("height"),
      frame: 0,
      observer: new ResizeObserver(measure),
    };
    function measure() {
      cancelAnimationFrame(placement.frame);
      placement.frame = requestAnimationFrame(() => {
        if (
          !host.isConnected ||
          placement.binding.message.dataset.msgTs !== placement.binding.ts
        )
          return;
        const current = rowBinding(
          placement.binding.message,
          placement.binding.ts,
        );
        if (current?.row !== placement.row) return;
        const height = placement.row.getBoundingClientRect().height;
        const measured =
          heights.get(current.resize) ??
          new Map<string, { thread: string; height: number }>();
        measured.set(current.ts, {
          thread: keyFor(thread),
          height: height - host.getBoundingClientRect().height,
        });
        heights.set(current.resize, measured);
        current.resize(current.ts, height);
      });
    }
    // BaseDynamicList tracks existing item keys, not additional sibling rows.
    binding.row.style.height = "auto";
    binding.row.append(host);
    placement.observer.observe(binding.row);
    placements.set(binding.row, placement);
    measure();
  }

  function scan(input: Iterable<SummaryRecord>): void {
    const records = [...input];
    const wanted = new Set<HTMLElement>();
    const messages = [
      ...document.querySelectorAll<HTMLElement>(
        '[data-qa="message_container"][data-msg-ts]',
      ),
    ];
    for (const record of records) {
      const cards = [
        ...(threads.get(keyFor(record.thread))?.values() ?? []),
      ].sort(
        (a, b) =>
          a.generatedAt.localeCompare(b.generatedAt) ||
          a.id.localeCompare(b.id),
      );
      if (!cards.length) {
        record.ui?.placementError("");
        continue;
      }
      const contexts = owners(record);
      let unsupported = false;
      for (const message of messages) {
        if (message.dataset.msgChannelId !== record.thread.channelId) continue;
        const atBoundary = cards.filter(
          (card) => card.throughTs === message.dataset.msgTs,
        );
        if (
          !atBoundary.length ||
          !ancestors(message).some(
            (fiber) => contexts.has(fiber) || contexts.has(fiber.stateNode),
          )
        )
          continue;
        const binding = rowBinding(message, message.dataset.msgTs);
        if (!binding) {
          unsupported = true;
          continue;
        }
        wanted.add(binding.row);
        const names: Record<string, string> = {};
        for (const card of atBoundary) {
          const text = [
            card.summary.overview,
            ...card.summary.decisions,
            ...card.summary.actions,
          ].join("\n");
          for (const match of text.matchAll(/<@([A-Z0-9]+)(?:\|[^>]+)?>/g)) {
            const id = match[1];
            if (!id) continue;
            names[id] = memberName(record, id) || id;
          }
        }
        const signature = JSON.stringify([
          keyFor(record.thread),
          atBoundary.map((card) => [card.id, card.saved]),
          names,
        ]);
        const existing = placements.get(binding.row);
        if (
          existing &&
          (existing.signature !== signature || !existing.host.isConnected)
        )
          remove(existing);
        if (!placements.has(binding.row))
          mount(binding, record.thread, atBoundary, signature, names);
        else {
          const placement = placements.get(binding.row);
          if (placement) placement.binding = binding;
          binding.row.style.height = "auto";
        }
      }
      record.ui?.placementError(
        unsupported
          ? "Saved summaries could not be placed in this thread view."
          : "",
      );
    }
    for (const placement of placements.values()) {
      if (!wanted.has(placement.row) || !placement.row.isConnected)
        remove(placement);
    }
    const active = new Set(records.map((record) => keyFor(record.thread)));
    for (const [resize, measured] of heights) {
      for (const [ts, entry] of measured) {
        if (active.has(entry.thread)) continue;
        // A virtualized row can be absent while its height is still cached.
        try {
          resize(ts, entry.height);
        } catch {}
        measured.delete(ts);
      }
      if (!measured.size) heights.delete(resize);
    }
  }

  return {
    merge,
    scan,
    stop() {
      for (const placement of placements.values()) remove(placement);
      for (const [resize, measured] of heights) {
        for (const [ts, entry] of measured) {
          try {
            resize(ts, entry.height);
          } catch {}
        }
      }
      heights.clear();
      threads.clear();
      deleted.clear();
    },
  };
}
