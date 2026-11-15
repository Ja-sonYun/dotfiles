function createReviewPanel(
  current: PendingReview,
  dependencies: ReviewPanelDependencies,
): ReviewPanel {
  const {
    draftTools,
    validSuggestion,
    readableSuggestion,
    suggestionParts,
    preparePatch,
    notify,
    beginStage,
    resolve,
    isSelected,
    disableSend,
  } = dependencies;
  const editor = current.record.element;
  const composerElement =
    editor.closest(".c-wysiwyg_container") ?? editor.parentElement;
  if (!composerElement) throw new Error("The composer is no longer available.");
  const composer = composerElement;
  const host = document.createElement("div");
  host.style.cssText = "position:fixed;z-index:1000;display:block";
  const root = host.attachShadow({ mode: "open" });
  const editorStyle = getComputedStyle(editor);
  host.style.colorScheme = editorStyle.colorScheme;
  host.style.setProperty("--message-font", editorStyle.fontFamily);
  host.style.setProperty("--message-size", editorStyle.fontSize);
  host.style.setProperty("--message-line-height", editorStyle.lineHeight);
  const style = document.createElement("style");
  style.textContent = `
      :host { color-scheme: light dark; font: 13px/1.45 system-ui, sans-serif; }
      * { box-sizing: border-box; }
      [hidden] { display:none !important; }
    section { background: light-dark(#f4faf5,#202a24); color: light-dark(#202124,#dce4de);
      border: 1px solid light-dark(#a6c2af,#57715f); border-radius: 8px;
      padding: 14px 16px; display:flex; flex-direction:column; overflow:auto; }
    section.busy { background:light-dark(#eff5f8,#26323a); border-color:light-dark(#b4c3cb,#47565e); padding:10px 13px; }
    .review-heading { display:flex;align-items:center;gap:8px;font-size:13px;font-weight:600;flex-shrink:0; }
    .review-heading .status { flex:1; }
    .text-button { border:0;background:transparent;padding:2px 3px;color:light-dark(#1264a3,#9bc7e1);font-size:11px; }
    .targetline { font-size:11px;color:light-dark(#52685a,#a8b9ad);margin-top:5px; }
    .compare { display:grid;grid-template-columns:minmax(0,1fr) minmax(0,1fr);gap:16px;margin-top:12px; }
    .suggested { padding-left:16px;border-left:1px solid light-dark(#c5d7cb,#46544a);min-width:0; }
    .original-box { min-width:0; }
    .compare h3 { font-size:10px;text-transform:uppercase;letter-spacing:.4px;margin:0 0 6px;color:light-dark(#536e5d,#a6bcad); }
    .original-text { white-space:pre-wrap;overflow-wrap:anywhere;font:inherit;font-size:12px;line-height:1.55; }
    .busy .body,.busy .bottom,.busy .targetline,.busy .activity { display:none; }
    .review-heading .cancel-running { display:none; }.busy .cancel-running { display:block; }
    .message-heading { display:none!important; }
    .suggested textarea,.suggested .mention-editor,.suggested .formatting,.ask { display:none; }
    .editing .suggested textarea,.editing .suggested .mention-editor { display:block; }
    .editing .suggested .formatting,.editing .ask { display:flex; }
    .activity { margin-top:10px;padding-top:8px;border-top:1px solid light-dark(#c5d7cb,#3b4b40);font-size:11px; }
    .activity summary { cursor:pointer; }.tool-row { display:flex;justify-content:space-between;gap:12px;margin-top:7px; }
    .dev-note { font-size:11px;color:light-dark(#805a14,#e0c08a);margin-top:8px; }
      .body { min-height:0; overflow:auto; }
      .status, .bottom { flex-shrink:0; }
      footer, .ask, .message-heading { display:flex; align-items:center; gap:8px; }
      .message-heading { justify-content:space-between; margin-bottom:5px; }
      .status { color:light-dark(#526476,#b5c7da); font-size:12px; }
      .busy .status::before { content:""; display:inline-block; width:10px; height:10px;
        border:2px solid #9daabc; border-top-color:transparent; border-radius:50%;
        margin-right:6px; animation:spin .8s linear infinite; }
      @keyframes spin { to { transform:rotate(360deg); } }
    @media (prefers-reduced-motion: reduce) { .busy .status::before { animation:none; } }
      .error { white-space:pre-wrap; overflow-wrap:anywhere; color:light-dark(#a12622,#ffb4ab); margin-bottom:8px; }
      .busy textarea, .busy .mention-editor { color:light-dark(#70757d,#a2a7af); opacity:.7; }
      label { display:block; font-size:12px; font-weight:600; margin:0; }
      textarea, input, .mention-editor { font:inherit; color:inherit; background:light-dark(#f7f8fa,#292b30);
        border:1px solid light-dark(#d7d9de,#555860); border-radius:7px; padding:8px; width:100%; }
      textarea, .mention-editor { resize:vertical; min-height:110px; max-height:360px; }
      .mention-editor { overflow:auto; white-space:pre-wrap; overflow-wrap:anywhere; }
      .mention { background:light-dark(#e4f1fa,#274556); border-radius:3px;
        display:inline-block; max-width:100%; overflow:hidden; text-overflow:ellipsis;
        white-space:nowrap; vertical-align:bottom; }
      .ask { margin:10px 0; }
      button { font:inherit; white-space:nowrap; cursor:pointer; padding:6px 10px;
        border:1px solid light-dark(#cfd3da,#555860); border-radius:6px;
        color:inherit; background:light-dark(#fff,#303238); }
    button.primary { background:#93c5a4; color:#17291e; border-color:#93c5a4; }
      button:disabled { opacity:.45; cursor:default; }
      footer { justify-content:flex-end; flex-wrap:wrap; }
      .note { font-size:11px; opacity:.65; margin-top:6px; }
      .assessment { margin-bottom:16px; overflow-wrap:anywhere; }
      .assessment > label { margin-top:14px; }
      .assessment > label:first-child { margin-top:0; }
      .assessment-text { margin-top:6px; line-height:1.55; }
      .assessment-text p { margin:0 0 8px; white-space:pre-wrap; }
      .assessment-text ul, .assessment-text ol { margin:6px 0 10px; padding-inline-start:22px; }
      .assessment-text li { margin:4px 0; white-space:pre-wrap; }
      .assessment-text li > ul, .assessment-text li > ol { margin:4px 0; }
      .assessment-text code { font-family:monospace; background:light-dark(#f3f3f3,#34363b); }
      .formatting { display:flex; flex-wrap:wrap; gap:4px; margin:0 0 6px; }
      button:focus-visible, textarea:focus-visible, .mention-editor:focus-visible {
        outline:2px solid light-dark(#1264a3,#8ac5f2); outline-offset:2px; }
      button:not(:disabled):hover { background:light-dark(#e8edf2,#41454d); }
      button[aria-pressed="true"] { background:light-dark(#e4f1fa,#274556);
        border-color:light-dark(#1264a3,#8ac5f2); }
    button.primary:not(:disabled):hover { background:#b1d7be; }
      .preview-heading { margin:14px 0 6px; }
      .preview { font-family:var(--message-font); font-size:var(--message-size);
        line-height:var(--message-line-height); padding:8px; min-width:0;
        white-space:pre-wrap; overflow-wrap:anywhere; }
      .preview-line { display:flex; min-width:0; }
      .preview-marker { flex:none; min-width:1.5em; padding-right:.5em; text-align:right; }
      .preview-content { min-width:0; flex:1; }
      .preview a { color:light-dark(#1264a3,#8ac5f2); }
      .preview code { font-family:monospace; background:light-dark(#f3f3f3,#34363b); }
      .preview blockquote { margin:0; border-left:2px solid light-dark(#aaa,#777); padding-left:10px; }
    `;
  root.append(style);
  function node<K extends keyof HTMLElementTagNameMap>(
    tag: K,
    text: string,
    parent: ParentNode,
    className?: string,
  ): HTMLElementTagNameMap[K] {
    const element = document.createElement(tag);
    if (text) element.textContent = text;
    if (className) element.className = className;
    parent.append(element);
    return element;
  }
  function renderAssessment(target: HTMLElement, text: string): void {
    target.replaceChildren();
    const lists: {
      indent: number;
      list: HTMLUListElement | HTMLOListElement;
      item: HTMLLIElement;
    }[] = [];
    let paragraph: HTMLParagraphElement | undefined;
    function inline(parent: HTMLElement, value: string): void {
      let position = 0;
      for (const match of value.matchAll(/(\*\*|__)(.+?)\1|`([^`]+)`/g)) {
        parent.append(
          document.createTextNode(value.slice(position, match.index)),
        );
        node(
          match[3] === undefined ? "strong" : "code",
          match[3] ?? match[2] ?? "",
          parent,
        );
        position = match.index + match[0].length;
      }
      parent.append(document.createTextNode(value.slice(position)));
    }
    for (const line of text.split(/\r?\n/)) {
      if (!line.trim()) {
        paragraph = undefined;
        continue;
      }
      const match = line.match(
        /^([ \t]*)(?:[-*+][ \t]+|[•・][ \t]*|(\d+)[.)][ \t]+)(.*)$/,
      );
      if (match) {
        paragraph = undefined;
        const indent = (match[1] ?? "").replace(/\t/g, "  ").length;
        const ordered = match[2] !== undefined;
        while (lists.length && (lists.at(-1)?.indent ?? 0) > indent)
          lists.pop();
        let current = lists.at(-1);
        if (
          current?.indent === indent &&
          current.list instanceof HTMLOListElement !== ordered
        ) {
          lists.pop();
          current = lists.at(-1);
        }
        if (!current || current.indent !== indent) {
          const list = node(ordered ? "ol" : "ul", "", current?.item ?? target);
          if (list instanceof HTMLOListElement) list.start = Number(match[2]);
          current = { indent, list, item: node("li", "", list) };
          lists.push(current);
        } else {
          current.item = node("li", "", current.list);
        }
        inline(current.item, match[3] ?? "");
      } else {
        const current = lists.at(-1);
        const indent = (line.match(/^[ \t]*/)?.[0] ?? "").replace(
          /\t/g,
          "  ",
        ).length;
        if (current && indent > current.indent) {
          current.item.append(document.createElement("br"));
          inline(current.item, line.trimStart());
        } else {
          lists.length = 0;
          if (paragraph) paragraph.append(document.createElement("br"));
          else paragraph = node("p", "", target);
          inline(paragraph, line);
        }
      }
    }
  }
  const panel = node("section", "", root, "busy");
  panel.setAttribute("role", "dialog");
  panel.setAttribute("aria-label", "Review message");
  const reviewHeading = node("header", "", panel, "review-heading");
  const cancelRunning = node(
    "button",
    "Cancel",
    reviewHeading,
    "text-button cancel-running",
  );
  cancelRunning.onclick = () => dependencies.cancel();
  const viewTasks = node(
    "button",
    "View in Tasks",
    reviewHeading,
    "text-button",
  );
  viewTasks.onclick = () => {
    dependencies.dismiss();
    window.__slackAiTasks?.open(current.id);
  };
  const targetline = node("div", "", panel, "targetline");
  const body = node("div", "", panel, "body");
  const errorMessage = node("div", "", body, "error");
  errorMessage.setAttribute("role", "alert");
  errorMessage.hidden = true;
  const assessmentPanel = node("details", "", body, "assessment");
  node("summary", "Review assessment", assessmentPanel);
  assessmentPanel.hidden = true;
  node("label", "Question", assessmentPanel);
  const coreQuestion = node("div", "", assessmentPanel, "assessment-text");
  node("label", "Draft assessment", assessmentPanel);
  const assessment = node("div", "", assessmentPanel, "assessment-text");
  const staleAssessment = node(
    "div",
    "Edited since review. Ask AI to reassess your changes.",
    assessmentPanel,
    "note",
  );
  staleAssessment.hidden = true;
  const heading = node("div", "", body, "message-heading");
  const label = node("label", "Message", heading);
  label.htmlFor = "suggestion";
  const status = node("span", "Reviewing…", heading, "status");
  status.setAttribute("role", "status");
  reviewHeading.prepend(status);
  const formatting = node("div", "", body, "formatting");
  formatting.setAttribute("role", "group");
  formatting.setAttribute("aria-label", "Message formatting");
  const bullets = node("button", "Bullets", formatting);
  const numbers = node("button", "Numbered list", formatting);
  const quote = node("button", "Quote", formatting);
  const indent = node("button", "Indent", formatting);
  const outdent = node("button", "Outdent", formatting);
  const suggestion = node(
    current.elements.length ? "div" : "textarea",
    "",
    body,
    current.elements.length ? "mention-editor" : "",
  );
  suggestion.id = "suggestion";
  suggestion.setAttribute("role", "textbox");
  suggestion.setAttribute("aria-label", "Message");
  suggestion.setAttribute("aria-multiline", "true");
  const comparison = node("div", "", body, "compare");
  const originalDetails = node("div", "", comparison, "original-box");
  node("h3", "Original", originalDetails);
  const originalText = node(
    "div",
    readableSuggestion(current, current.previewOriginal),
    originalDetails,
    "original-text",
  );
  originalText.setAttribute("aria-label", "Original message");
  const previewHeading = node(
    "label",
    "Message preview",
    body,
    "preview-heading",
  );
  const preview = node("div", "", body, "preview");
  preview.setAttribute("role", "region");
  preview.setAttribute("aria-label", "Message preview");
  const suggestedBox = node("div", "", comparison, "suggested");
  node("h3", "Suggested", suggestedBox);
  suggestedBox.append(formatting, suggestion, preview);
  previewHeading.hidden = true;
  let suggestionError: string | undefined;
  let hasSuggestion = false;
  let reviewedSuggestion: string | undefined;
  let suggestionWidth = 0;
  let lastValidText = current.previewOriginal;
  let lineFormats = current.projection.lines.map((line) => ({ ...line }));
  let prepared: DraftPatch | undefined;
  let selectedLines = { start: 0, end: 0 };
  let inputSelection: { start: number; end: number } | undefined;
  const bottom = node("div", "", panel, "bottom");
  const askRow = node("div", "", bottom, "ask");
  const question = node("input", "", askRow);
  question.placeholder = "Ask for changes…";
  question.setAttribute("aria-label", "Ask for changes");
  const ask = node("button", "Ask AI", askRow);
  const footer = node("footer", "", bottom);
  const cancel = node("button", "Cancel", footer);
  const dismiss = node("button", "Close", reviewHeading, "text-button");
  dismiss.onclick = () => dependencies.dismiss();
  const edit = node("button", "Edit", footer);
  edit.onclick = () => {
    panel.classList.toggle("editing");
    edit.textContent = panel.classList.contains("editing")
      ? "Done editing"
      : "Edit";
    if (panel.classList.contains("editing")) suggestion.focus();
    refresh();
  };
  const retry = node("button", "Retry", footer);
  const check = node("button", "Check with AI", footer);
  const original = node("button", "Use original", footer);
  const revised = node("button", "Apply suggestion", footer, "primary");
  const note = node("div", "", bottom, "note");
  const activity = node("details", "", panel, "activity");
  const activityLabel = node("summary", "Tool activity", activity);
  const activityRows = node("div", "", activity);
  if (disableSend)
    node("div", "Development workspace · Sending disabled", panel, "dev-note");

  const chips = new WeakMap<Node, string>();
  function readSuggestionNode(element: Node): string {
    if (element.nodeType === Node.TEXT_NODE) return element.textContent ?? "";
    const token = chips.get(element);
    if (token !== undefined) return token;
    if (element.nodeName === "BR") return "\n";
    const text = [...element.childNodes].map(readSuggestionNode).join("");
    return ["DIV", "P"].includes(element.nodeName) && element !== suggestion
      ? `${text}\n`
      : text;
  }
  function suggestionText(): string {
    if (suggestion instanceof HTMLTextAreaElement) return suggestion.value;
    return readSuggestionNode(suggestion);
  }

  function renderPreview(patch: DraftPatch): void {
    preview.replaceChildren();
    let line: DeltaUnit[] = [];
    const counters: number[] = [];
    let previousDepth = -1;
    for (const unit of patch.expected) {
      if (unit.insert !== "\n") {
        line.push(unit);
        continue;
      }
      const row = node("div", "", preview, "preview-line");
      const depth = unit.attributes.indent ?? 0;
      if (unit.attributes.list) {
        row.style.paddingInlineStart = `${depth * 24}px`;
        const ordered = unit.attributes.list === "ordered";
        if (ordered && depth > previousDepth) counters[depth] = 0;
        const number = (counters[depth] ?? 0) + 1;
        if (ordered) counters[depth] = number;
        previousDepth = depth;
        node("span", ordered ? `${number}.` : "•", row, "preview-marker");
      } else {
        counters.length = 0;
        previousDepth = -1;
      }
      const content = node("div", "", row, "preview-content");
      const target = unit.attributes["code-block"]
        ? node("code", "", content)
        : unit.attributes.blockquote
          ? node("blockquote", "", content)
          : content;
      let run: HTMLElement | undefined;
      let previousAttributes = "";
      for (const item of line) {
        const key = JSON.stringify(item.attributes);
        if (
          !run ||
          key !== previousAttributes ||
          typeof item.insert !== "string"
        ) {
          run = node(
            item.attributes.link ? "a" : item.attributes.code ? "code" : "span",
            "",
            target,
          );
          if (
            run instanceof HTMLAnchorElement &&
            typeof item.attributes.link === "string"
          ) {
            run.title = item.attributes.link;
            if (/^https?:\/\//i.test(item.attributes.link)) {
              run.href = item.attributes.link;
              run.target = "_blank";
              run.rel = "noopener noreferrer";
            }
          }
          if (item.attributes.bold) run.style.fontWeight = "700";
          if (item.attributes.italic) run.style.fontStyle = "italic";
          if (item.attributes.strike) run.style.textDecoration = "line-through";
          if (item.attributes.slackmention) run.className = "mention";
          previousAttributes = key;
        }
        if (typeof item.insert === "string")
          run.append(document.createTextNode(item.insert));
        else {
          const element = current.elements.find((entry) =>
            entry.units.some(
              (part) =>
                typeof part.insert !== "string" &&
                JSON.stringify(part.insert) === JSON.stringify(item.insert),
            ),
          );
          run.textContent = element?.label ?? "[Embedded element]";
          run = undefined;
        }
      }
      if (!line.length) target.append(document.createElement("br"));
      line = [];
    }
  }
  function resizeSuggestion() {
    if (!suggestion.isConnected) return;
    const scrollTop = suggestion.scrollTop;
    suggestion.style.height = "auto";
    suggestion.style.height = `${Math.min(360, Math.max(110, suggestion.scrollHeight + 2))}px`;
    suggestion.scrollTop = scrollTop;
    suggestionWidth = suggestion.clientWidth;
  }
  function updateSuggestionState() {
    prepared = undefined;
    let previewError: string | undefined;
    if (!suggestionError && validSuggestion(current, suggestionText())) {
      try {
        prepared = preparePatch(current, suggestionText(), lineFormats);
        renderPreview(prepared);
      } catch (error) {
        prepared = undefined;
        previewError = error instanceof Error ? error.message : String(error);
      }
    }
    if (!prepared) preview.replaceChildren();
    const valid = !suggestionError && Boolean(prepared);
    revised.disabled =
      disableSend ||
      current.busy ||
      current.applyFailed ||
      !hasSuggestion ||
      !valid;
    staleAssessment.hidden =
      assessmentPanel.hidden ||
      draftTools.serialize(suggestionText(), lineFormats) ===
        reviewedSuggestion;
    note.textContent =
      suggestionError ||
      previewError ||
      (!valid
        ? "Keep protected elements in their original order."
        : /\\(?:r\\n|n)/.test(suggestionText())
          ? "Literal escape sequences were kept. Replace them with line breaks here if needed."
          : "");
    note.hidden = !note.textContent;
    for (const button of [bullets, numbers, quote, indent, outdent])
      button.disabled =
        current.busy || current.applyFailed || !hasSuggestion || !valid;
    const selected = lineFormats.slice(
      selectedLines.start,
      selectedLines.end + 1,
    );
    bullets.setAttribute(
      "aria-pressed",
      String(
        selected.length > 0 && selected.every((line) => line.list === "bullet"),
      ),
    );
    numbers.setAttribute(
      "aria-pressed",
      String(
        selected.length > 0 &&
          selected.every((line) => line.list === "ordered"),
      ),
    );
    quote.setAttribute(
      "aria-pressed",
      String(
        selected.length > 0 &&
          selected.every((line) => Boolean(line.blockquote)),
      ),
    );
    resizeSuggestion();
  }
  function setSuggestion(text: string, normalize = false): void {
    inputSelection = undefined;
    suggestionError = validSuggestion(current, text)
      ? undefined
      : "The suggestion changed protected elements or is empty. Retry the review.";
    if (normalize && !suggestionError) {
      try {
        const patch = preparePatch(current, text);
        text = patch.text;
        lineFormats = patch.lines;
        selectedLines = { start: 0, end: 0 };
      } catch (error) {
        suggestionError =
          error instanceof Error ? error.message : String(error);
        updateSuggestionState();
        return;
      }
    }
    if (suggestion instanceof HTMLTextAreaElement) {
      suggestion.value = readableSuggestion(current, text);
    } else {
      suggestion.replaceChildren();
      for (const part of suggestionParts(text)) {
        const mention = current.elements.find(({ token }) => token === part);
        if (mention) {
          const chip = node("span", mention.label, suggestion, "mention");
          chip.title = mention.href ?? mention.label;
          chip.contentEditable = "false";
          chips.set(chip, mention.token);
        } else {
          suggestion.append(
            document.createTextNode(readableSuggestion(current, part)),
          );
        }
      }
    }
    lastValidText = text;
    updateSuggestionState();
  }
  function rememberSelection(): { start: number; end: number } | undefined {
    let start: number;
    let end: number;
    if (suggestion instanceof HTMLTextAreaElement) {
      start = suggestion.selectionStart;
      end = suggestion.selectionEnd;
    } else {
      const selection = root.getSelection?.() ?? window.getSelection();
      if (!selection?.rangeCount) return;
      const range = selection.getRangeAt(0);
      if (!suggestion.contains(range.commonAncestorContainer)) return;
      function offset(container: Node, position: number): number {
        let total = 0;
        function visit(element: Node): boolean {
          if (element === container) {
            total +=
              element.nodeType === Node.TEXT_NODE
                ? (element.textContent ?? "").slice(0, position).length
                : [...element.childNodes]
                    .slice(0, position)
                    .map(readSuggestionNode)
                    .join("").length;
            return true;
          }
          if (!element.contains(container)) {
            total += readSuggestionNode(element).length;
            return false;
          }
          return [...element.childNodes].some(visit);
        }
        visit(suggestion);
        return total;
      }
      start = offset(range.startContainer, range.startOffset);
      end = offset(range.endContainer, range.endOffset);
    }
    const text = suggestionText();
    selectedLines = {
      start: text.slice(0, start).split("\n").length - 1,
      end:
        text
          .slice(0, end > start && text[end - 1] === "\n" ? end - 1 : end)
          .split("\n").length - 1,
    };
    return { start, end };
  }
  for (const event of ["select", "keyup", "mouseup", "focusout"])
    suggestion.addEventListener(event, rememberSelection);
  suggestion.addEventListener("beforeinput", (event) => {
    inputSelection =
      event instanceof InputEvent && event.inputType.startsWith("history")
        ? undefined
        : rememberSelection();
  });
  formatting.onmousedown = (event) => {
    rememberSelection();
    event.preventDefault();
  };
  function formatLines(
    action: "bullet" | "ordered" | "quote" | "indent" | "outdent",
  ): void {
    if (current.busy || current.applyFailed || !hasSuggestion || !prepared)
      return;
    const selected = lineFormats.slice(
      selectedLines.start,
      selectedLines.end + 1,
    );
    const remove =
      selected.length > 0 &&
      selected.every((line) =>
        action === "quote" ? Boolean(line.blockquote) : line.list === action,
      );
    if (selected.some((line) => line["code-block"])) {
      note.textContent =
        "List and quote formatting is unavailable inside code blocks.";
      note.hidden = false;
      return;
    }
    lineFormats = lineFormats.map((line, index) => {
      if (index < selectedLines.start || index > selectedLines.end) return line;
      const next = { ...line };
      if (action === "quote") {
        delete next.list;
        delete next.indent;
        if (remove) delete next.blockquote;
        else next.blockquote = true;
      } else if (action === "bullet" || action === "ordered") {
        delete next.blockquote;
        if (remove) {
          delete next.list;
          delete next.indent;
        } else {
          next.list = action;
        }
      } else if (next.list) {
        const depth = Math.max(
          0,
          Math.min(4, (next.indent ?? 0) + (action === "indent" ? 1 : -1)),
        );
        if (depth) next.indent = depth;
        else delete next.indent;
      }
      return next;
    });
    if (current.result && !("error" in current.result)) {
      current.result = {
        ...current.result,
        suggestion: draftTools.serialize(suggestionText(), lineFormats),
      };
    }
    updateSuggestionState();
  }
  bullets.onclick = () => formatLines("bullet");
  numbers.onclick = () => formatLines("ordered");
  quote.onclick = () => formatLines("quote");
  indent.onclick = () => formatLines("indent");
  outdent.onclick = () => formatLines("outdent");
  function acceptEdit(): void {
    try {
      lineFormats = draftTools.editLines(
        lastValidText,
        suggestionText(),
        lineFormats,
        inputSelection,
      );
      lastValidText = suggestionText();
      if (current.result && !("error" in current.result)) {
        current.result = {
          ...current.result,
          suggestion: draftTools.serialize(lastValidText, lineFormats),
        };
      }
      suggestionError = undefined;
    } catch (error) {
      suggestionError = error instanceof Error ? error.message : String(error);
    } finally {
      inputSelection = undefined;
    }
    updateSuggestionState();
  }
  function insertText(text: string): void {
    const selection = root.getSelection?.() ?? window.getSelection();
    if (!selection?.rangeCount) return;
    const range = selection.getRangeAt(0);
    if (!suggestion.contains(range.commonAncestorContainer)) return;
    if (
      [...suggestion.querySelectorAll(".mention")].some((chip) =>
        range.intersectsNode(chip),
      )
    )
      return;
    inputSelection = rememberSelection();
    range.deleteContents();
    const inserted = document.createTextNode(text);
    range.insertNode(inserted);
    range.setStartAfter(inserted);
    range.collapse(true);
    selection.removeAllRanges();
    selection.addRange(range);
    if (!validSuggestion(current, suggestionText())) {
      setSuggestion(lastValidText);
      return;
    }
    acceptEdit();
  }
  if (current.elements.length) {
    suggestion.addEventListener("beforeinput", (event) => {
      if (!(event instanceof InputEvent)) return;
      for (const target of event.getTargetRanges()) {
        const range = document.createRange();
        range.setStart(target.startContainer, target.startOffset);
        range.setEnd(target.endContainer, target.endOffset);
        if (
          !range.collapsed &&
          [...suggestion.querySelectorAll(".mention")].some((chip) =>
            range.intersectsNode(chip),
          )
        ) {
          event.preventDefault();
          return;
        }
      }
      if (["insertParagraph", "insertLineBreak"].includes(event.inputType)) {
        event.preventDefault();
        if (!current.busy && hasSuggestion) insertText("\n");
      }
    });
    suggestion.addEventListener("paste", (event) => {
      if (!(event instanceof ClipboardEvent)) return;
      event.preventDefault();
      if (!current.busy && hasSuggestion)
        insertText(event.clipboardData?.getData("text/plain") ?? "");
    });
    suggestion.addEventListener("drop", (event) => event.preventDefault());
  }
  setSuggestion(current.previewOriginal);

  function setBusy(busy: boolean): void {
    current.busy = busy;
    const confirming = current.phase === "confirm";
    panel.classList.toggle("busy", busy);
    panel.setAttribute(
      "aria-label",
      confirming ? "Confirm message" : "Review message",
    );
    askRow.hidden = confirming;
    check.hidden = !confirming;
    check.disabled = busy;
    revised.hidden = confirming;
    original.textContent = "Use original";
    original.classList.toggle("primary", confirming);
    if (busy) status.hidden = false;
    ask.disabled = busy || current.phase !== "review";
    question.disabled = busy || current.phase !== "review";
    original.disabled = busy || disableSend;
    revised.disabled =
      disableSend ||
      busy ||
      !hasSuggestion ||
      Boolean(suggestionError) ||
      !validSuggestion(current, suggestionText());
    if (suggestion instanceof HTMLTextAreaElement)
      suggestion.readOnly = busy || !hasSuggestion;
    if (current.elements.length)
      suggestion.contentEditable = busy || !hasSuggestion ? "false" : "true";
    formatting.hidden = confirming;
    preview.hidden = confirming;
    previewHeading.hidden = true;
    edit.hidden = confirming;
    edit.disabled = busy || !hasSuggestion;
    suggestedBox.hidden = confirming;
    status.hidden = false;
    status.textContent = busy
      ? "Reviewing · Not sent"
      : confirming
        ? "Confirm message · Not sent"
        : "Review complete · Not sent";
    updateSuggestionState();
  }
  function setStage(stage: "loading" | "checking" | "review"): void {
    current.phase = stage;
    retry.hidden = true;
    errorMessage.hidden = true;
    status.textContent =
      stage === "loading"
        ? "Loading thread · Not sent"
        : stage === "checking"
          ? "Checking · Not sent"
          : "Reviewing · Not sent";
    setBusy(true);
    refresh();
  }
  function classificationFailed(error: string): void {
    current.phase = "classification-error";
    setBusy(false);
    status.hidden = false;
    status.textContent = "Check failed";
    errorMessage.textContent = error;
    errorMessage.hidden = false;
    retry.hidden = false;
    refresh();
    retry.focus();
  }
  function askAI() {
    const instruction = question.value.trim();
    if (
      current.busy ||
      current.applyFailed ||
      current.phase !== "review" ||
      !instruction ||
      !validSuggestion(current, suggestionText()) ||
      !isSelected(current)
    )
      return;
    errorMessage.hidden = true;
    question.value = "";
    current.turn++;
    setBusy(true);
    status.textContent = "Reviewing…";
    try {
      notify({
        kind: "ask",
        id: current.id,
        turn: current.turn,
        instruction,
        suggestion: draftTools.serialize(suggestionText(), lineFormats),
      });
    } catch {
      current.ui?.receive({
        error:
          "Review connection unavailable. Cancel and restart the controller.",
      });
    }
  }
  ask.onclick = askAI;
  question.onkeydown = (event) => {
    if (event.key === "Enter" && !event.isComposing) {
      event.preventDefault();
      askAI();
    }
  };
  root.addEventListener("keydown", (event) => {
    event.stopPropagation();
    if (event instanceof KeyboardEvent && event.key === "Escape")
      dependencies.cancel();
  });
  root.addEventListener("click", (event) => event.stopPropagation());
  suggestion.oninput = () => {
    if (
      current.elements.length &&
      !validSuggestion(current, suggestionText())
    ) {
      setSuggestion(lastValidText);
      return;
    }
    acceptEdit();
  };
  cancel.onclick = () => dependencies.cancel();
  check.onclick = () => {
    if (!isSelected(current) || current.busy || current.phase !== "confirm")
      return;
    current.turn++;
    beginStage(current, "review");
  };
  retry.onclick = () => {
    if (!isSelected(current) || current.busy) return;
    current.turn++;
    beginStage(current, current.initialStage);
  };
  original.onclick = () =>
    resolve(current.id, { action: "original", text: current.original });
  revised.onclick = () => {
    if (prepared)
      resolve(current.id, {
        action: "revised",
        text: suggestionText(),
        patch: prepared,
      });
  };

  // Keep the review outside React's tree while anchoring it to the active composer.
  function refresh() {
    for (
      let surface: HTMLElement | null = editor;
      surface;
      surface = surface.parentElement
    ) {
      const color = getComputedStyle(surface)
        .backgroundColor.match(/[\d.]+/g)
        ?.map(Number);
      if (color && color.length >= 3 && (color[3] ?? 1) === 1) {
        const [red = 0, green = 0, blue = 0] = color;
        host.style.colorScheme =
          red * 0.2126 + green * 0.7152 + blue * 0.0722 < 128
            ? "dark"
            : "light";
        break;
      }
    }
    const rect = composer.getBoundingClientRect();
    const width = Math.min(Math.max(280, rect.width), innerWidth - 24);
    host.style.width = width + "px";
    host.style.left =
      Math.max(12, Math.min(rect.left, innerWidth - width - 12)) + "px";
    host.style.bottom = Math.max(12, innerHeight - rect.top + 8) + "px";
    panel.style.maxHeight = Math.max(80, rect.top - 54) + "px";
    const props = { ...current.record.parent?.props, ...current.record.raw };
    targetline.textContent = [
      `To ${current.context?.conversation || props.channelDisplayName || props.channel?.name || "this conversation"}`,
      props.threadTs ? "Thread reply" : "",
      "Original draft and attachments retained",
    ]
      .filter(Boolean)
      .join(" · ");
    const tools = current.tools ?? [];
    activityLabel.textContent = tools.length
      ? `Tool activity · ${tools.filter((tool) => tool.status !== "running").length} finished · ${tools.length} total`
      : "No tool activity reported";
    activityRows.replaceChildren();
    for (const tool of tools) {
      const row = node("div", "", activityRows, "tool-row");
      node(
        "span",
        [tool.server, tool.tool ?? tool.type].filter(Boolean).join(" · "),
        row,
      );
      node(
        "span",
        `${tool.status}${typeof tool.elapsedMs === "number" ? ` · ${(tool.elapsedMs / 1000).toFixed(1)}s` : ""}`,
        row,
      );
    }
    if (suggestion.clientWidth !== suggestionWidth) resizeSuggestion();
  }
  document.body.append(host);
  setBusy(true);
  refresh();
  return {
    refresh,
    conflict(text, useCurrent) {
      setBusy(false);
      status.textContent = "Draft conflict · Not sent";
      errorMessage.textContent =
        "Your current draft is preserved. Choose it below, then press Slack Send to review it.";
      errorMessage.hidden = false;
      assessmentPanel.hidden = true;
      askRow.hidden = true;
      suggestedBox.hidden = true;
      const currentBox = node("div", "", comparison, "original-box");
      node("h3", "Current draft", currentBox);
      const currentText = node(
        "div",
        text || "(Empty draft)",
        currentBox,
        "original-text",
      );
      currentText.setAttribute("aria-label", "Current draft");
      for (const button of [edit, retry, check, original, revised])
        button.hidden = true;
      const useDraft = node(
        "button",
        "Use current draft for review",
        footer,
        "primary",
      );
      useDraft.onclick = useCurrent;
    },
    setStage,
    classificationFailed,
    sendFailed(message) {
      setBusy(false);
      errorMessage.textContent = message;
      errorMessage.hidden = false;
      status.hidden = false;
      status.textContent = "Send needs attention";
      if (current.applyFailed) {
        for (const button of [bullets, numbers, quote, indent, outdent])
          button.disabled = true;
        original.disabled = true;
        revised.disabled = true;
        ask.disabled = true;
        retry.hidden = true;
        check.disabled = true;
        if (suggestion instanceof HTMLTextAreaElement)
          suggestion.readOnly = true;
        if (current.elements.length) suggestion.contentEditable = "false";
      }
    },
    confirm() {
      current.phase = "confirm";
      retry.hidden = true;
      errorMessage.hidden = true;
      assessmentPanel.hidden = true;
      status.hidden = true;
      setBusy(false);
      refresh();
      check.focus();
    },
    receive(result) {
      if ("error" in result) {
        status.hidden = false;
        status.textContent = "Review failed";
        errorMessage.textContent = result.error;
        errorMessage.hidden = false;
        retry.hidden = hasSuggestion;
      } else {
        retry.hidden = true;
        hasSuggestion = true;
        status.textContent = "";
        status.hidden = true;
        errorMessage.hidden = true;
        label.textContent = "Suggested message";
        suggestion.setAttribute("aria-label", "Suggested message");
        assessmentPanel.hidden = current.context?.position !== "Thread";
        renderAssessment(
          coreQuestion,
          readableSuggestion(current, result.coreQuestion ?? ""),
        );
        renderAssessment(
          assessment,
          readableSuggestion(current, result.assessment ?? ""),
        );
        setSuggestion(result.suggestion, true);
        reviewedSuggestion = draftTools.serialize(
          suggestionText(),
          lineFormats,
        );
        updateSuggestionState();
      }
      setBusy(false);
      if ("error" in result) status.textContent = "Review failed · Not sent";
      refresh();
    },
    close() {
      host.remove();
    },
  };
}
