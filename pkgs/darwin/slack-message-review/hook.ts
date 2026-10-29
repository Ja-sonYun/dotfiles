(() => {
  function isRecord(value: unknown): value is Record<string, unknown> {
    return typeof value === "object" && value !== null && !Array.isArray(value);
  }

  function errorMessage(error: unknown): string {
    return error instanceof Error ? error.message : String(error);
  }

  function optionalString(value: unknown): string | undefined {
    if (value === undefined || value === null) return undefined;
    if (typeof value !== "string")
      throw new Error("Unsupported Slack text field.");
    return value;
  }

  function slackProps(value: unknown): SlackProps {
    if (value === undefined || value === null) return {};
    if (!isRecord(value)) throw new Error("Unsupported Slack properties.");
    const channel = value.channel;
    const draft = value.draft;
    if (channel != null && !isRecord(channel))
      throw new Error("Unsupported Slack channel.");
    if (draft != null && !isRecord(draft))
      throw new Error("Unsupported Slack draft.");
    if (
      value.isComposerPage !== undefined &&
      typeof value.isComposerPage !== "boolean"
    )
      throw new Error("Unsupported Slack composer.");
    return {
      ...value,
      teamId: optionalString(value.teamId),
      channelId: optionalString(value.channelId),
      threadTs: optionalString(value.threadTs),
      channelDisplayName: optionalString(value.channelDisplayName),
      channel: isRecord(channel)
        ? { name: optionalString(channel.name) }
        : undefined,
      draft: isRecord(draft) ? draft : undefined,
      isComposerPage: value.isComposerPage,
    };
  }

  function displayName(value: unknown): string | undefined {
    if (!isRecord(value) || typeof value.constructor !== "function")
      return undefined;
    const name: unknown = Reflect.get(value.constructor, "displayName");
    return typeof name === "string" ? name : undefined;
  }

  function fiberProps(
    fiber: Record<string, unknown>,
  ): Record<string, unknown> | undefined {
    const node = fiber.stateNode;
    const props =
      (isRecord(node) ? node.props : undefined) ?? fiber.memoizedProps;
    return isRecord(props) ? props : undefined;
  }

  function readMessage(value: unknown): SlackMessage | undefined {
    if (value === undefined || value === null) return undefined;
    if (!isRecord(value) || typeof value.ts !== "string")
      throw new Error("Unsupported Slack thread message.");
    if (
      value.reply_count !== undefined &&
      typeof value.reply_count !== "number"
    )
      throw new Error("Unsupported Slack reply count.");
    const bot = value.bot_profile;
    return {
      ts: value.ts,
      thread_ts: optionalString(value.thread_ts),
      channel: optionalString(value.channel),
      text: optionalString(value.text),
      user: optionalString(value.user),
      username: optionalString(value.username),
      bot_profile: isRecord(bot)
        ? { name: optionalString(bot.name) }
        : undefined,
      reply_count: value.reply_count,
      latest_reply: optionalString(value.latest_reply),
    };
  }

  function readThread(
    value: Record<string, unknown>,
    load: unknown,
    root?: unknown,
  ): ThreadSource {
    if (
      typeof value.channelId !== "string" ||
      typeof value.threadTs !== "string" ||
      !Array.isArray(value.timestamps) ||
      !value.timestamps.every((ts: unknown) => typeof ts === "string") ||
      !isRecord(value.messages)
    )
      throw new Error("Unsupported Slack thread history.");
    const messages = Object.fromEntries(
      Object.entries(value.messages).map(([ts, message]) => [
        ts,
        readMessage(message),
      ]),
    );
    return {
      channelId: value.channelId,
      threadTs: value.threadTs,
      timestamps: value.timestamps,
      messages,
      rootMsg: readMessage(root ?? value.rootMsg),
      reachedStart: value.reachedStart === true,
      load:
        typeof load === "function"
          ? (args: HistoryArgs): unknown =>
              Reflect.apply(load, undefined, [args])
          : undefined,
    };
  }

  function memberNameFor(
    element: Element,
    id: string | undefined,
  ): string | undefined {
    if (!id) return undefined;
    const props = ancestors(element)
      .map(fiberProps)
      .find((candidate) => typeof candidate?.getMember === "function");
    if (typeof props?.getMember !== "function") return undefined;
    const member: unknown = Reflect.apply(props.getMember, props, [id]);
    if (!isRecord(member)) return undefined;
    const profile = isRecord(member.profile) ? member.profile : {};
    return (
      optionalString(profile.display_name) ||
      optionalString(profile.real_name) ||
      optionalString(member.real_name) ||
      optionalString(member.name)
    );
  }

  if (window !== window.top || location.origin !== "https://app.slack.com") {
    return;
  }
  if (window.__slackMessageReview) {
    throw new Error(
      "Slack review hook is already installed. Stop its controller first.",
    );
  }
  function isComposerProps(value: unknown): value is ComposerProps {
    if (!isRecord(value) || typeof value.sendMessage !== "function")
      return false;
    try {
      slackProps(value);
      return true;
    } catch {
      return false;
    }
  }

  function isMessageInput(value: unknown): value is MessageInput {
    return (
      isRecord(value) &&
      isComposerProps(value.props) &&
      typeof value.getInputRef === "function"
    );
  }

  function isParent(value: unknown): value is ComposerParent {
    if (
      !isRecord(value) ||
      !isRecord(value.props) ||
      (value.state !== undefined && !isRecord(value.state))
    )
      return false;
    try {
      slackProps(value.props);
      return true;
    } catch {
      return false;
    }
  }

  function isInput(value: unknown): value is EditorInput {
    if (
      !isRecord(value) ||
      typeof value.getContents !== "function" ||
      (value.updateContents !== undefined &&
        typeof value.updateContents !== "function") ||
      (value.convertSlackHTMLToDelta !== undefined &&
        typeof value.convertSlackHTMLToDelta !== "function") ||
      (value.quill !== undefined && !isRecord(value.quill))
    )
      return false;
    return (
      value.instance === undefined ||
      (isRecord(value.instance) &&
        (value.instance.quill === undefined || isRecord(value.instance.quill)))
    );
  }

  function inputFor(record: ComposerRecord): EditorInput | undefined {
    const input = record.instance.getInputRef();
    if (input == null) return undefined;
    if (!isInput(input)) throw new Error("Unsupported Slack editor.");
    return input;
  }

  function readOps(value: unknown): InsertOp[] {
    if (!Array.isArray(value))
      throw new Error("Unsupported Slack draft format.");
    return value.map((op: unknown): InsertOp => {
      if (
        !isRecord(op) ||
        (typeof op.insert !== "string" && !isRecord(op.insert))
      )
        throw new Error("Unsupported Slack draft operation.");
      if (op.attributes === undefined) return { insert: op.insert };
      const attributes = op.attributes;
      if (
        !isRecord(attributes) ||
        (attributes.link !== undefined &&
          typeof attributes.link !== "string") ||
        (attributes.indent !== undefined &&
          typeof attributes.indent !== "number") ||
        (attributes.list !== undefined && typeof attributes.list !== "string")
      )
        throw new Error("Unsupported Slack draft attributes.");
      return {
        insert: op.insert,
        attributes: {
          ...attributes,
          ...(attributes.link === undefined ? {} : { link: attributes.link }),
          ...(attributes.indent === undefined
            ? {}
            : { indent: attributes.indent }),
          ...(attributes.list === undefined ? {} : { list: attributes.list }),
        },
      };
    });
  }

  function readContents(
    value: unknown,
  ): Record<string, unknown> & { contents: InsertOp[] } {
    if (!isRecord(value)) throw new Error("Unsupported Slack draft format.");
    return { ...value, contents: readOps(value.contents) };
  }

  function readSnapshot(
    text: string,
  ): Record<string, unknown> & { contents: ReturnType<typeof readContents> } {
    const value: unknown = JSON.parse(text);
    if (!isRecord(value)) throw new Error("Invalid Slack draft snapshot.");
    return { ...value, contents: readContents(value.contents) };
  }

  const owner = "@controllerId@";
  // The controller substitutes the compiled draft factory before injection.
  const injectedDraft = /* @draft@ */ null as DraftTools | null;
  if (!injectedDraft) throw new Error("Slack draft tools were not installed.");
  const draftTools = injectedDraft;
  let lastPulse = Date.now();
  const records = new Map<MessageInput, ComposerRecord>();
  let pending: PendingReview | undefined;
  let stopped = false;

  function notify(message: ReviewRequest): void {
    window.__slackReviewBridge(JSON.stringify(message));
  }

  function ancestors(element: Element): Record<string, unknown>[] {
    let fiber: unknown;
    for (
      let node: Element | null = element;
      node && !fiber;
      node = node.parentElement
    ) {
      const key = Object.keys(node).find((name) =>
        name.startsWith("__reactFiber$"),
      );
      if (key) fiber = Reflect.get(node, key);
    }
    const result: Record<string, unknown>[] = [];
    for (; isRecord(fiber); fiber = fiber.return) result.push(fiber);
    return result;
  }

  function threadSource(
    record: ComposerRecord,
    props: SlackProps,
  ): ThreadSource {
    const candidates = ancestors(record.element);
    for (const panel of document.querySelectorAll(
      '[data-qa="threads_flexpane"], .p-threads_flexpane_container',
    ))
      candidates.push(...ancestors(panel));
    for (const fiber of candidates) {
      const candidate = fiberProps(fiber);
      if (!candidate) continue;
      const thread = Array.isArray(candidate.threads)
        ? candidate.threads.find(
            (item: unknown) =>
              isRecord(item) &&
              item.channelId === props.channelId &&
              item.threadTs === props.threadTs,
          )
        : undefined;
      if (isRecord(thread)) {
        const root =
          isRecord(thread.messages) && props.threadTs
            ? thread.messages[props.threadTs]
            : undefined;
        return readThread(thread, candidate.requestReplies, root);
      }
      if (
        candidate.rootMsg &&
        candidate.channelId === props.channelId &&
        candidate.threadTs === props.threadTs &&
        Array.isArray(candidate.timestamps)
      )
        return readThread(candidate, candidate.requestHistory);
    }
    throw new Error(
      "This thread view is not supported. Cancel and open the thread in the side panel.",
    );
  }

  function threadMessages(
    thread: ThreadSource,
    props: SlackProps,
    fetched?: (SlackMessage | undefined)[],
  ): SlackMessage[] | undefined {
    const root = thread.rootMsg;
    if (!root || root.ts !== props.threadTs) return;
    const messages =
      fetched ?? thread.timestamps.map((ts) => thread.messages?.[ts]);
    const replies = [
      ...new Map(
        messages
          .filter(
            (message): message is SlackMessage =>
              message !== undefined &&
              message.thread_ts === props.threadTs &&
              message.ts !== props.threadTs &&
              (!message.channel || message.channel === props.channelId),
          )
          .map((message) => [message.ts, message]),
      ).values(),
    ]
      .sort((a, b) => a.ts.localeCompare(b.ts))
      .slice(-9);
    const count =
      root.reply_count ??
      (!root.latest_reply && thread.reachedStart ? 0 : undefined);
    if (
      typeof count !== "number" ||
      !Number.isInteger(count) ||
      replies.length !== Math.min(9, count) ||
      (count > 0 && replies.at(-1)?.ts !== root.latest_reply)
    )
      return;
    return [root, ...replies];
  }

  async function contextFor(
    current: PendingReview,
  ): Promise<ReviewContext | undefined> {
    const record = current.record;
    const props = { ...record.parent?.props, ...record.raw };
    const context: ReviewContext = {
      workspace:
        document
          .querySelector('[data-qa="workspace_actions_button"]')
          ?.textContent?.trim() ||
        document
          .querySelector('[data-qa="team-icon"]')
          ?.getAttribute("aria-label") ||
        "",
      conversation: props.isComposerPage
        ? record.element
            .closest(".p-composer_page")
            ?.querySelector(".p-composer_page__destination_text")
            ?.getAttribute("aria-label") || ""
        : (props.channelDisplayName ?? props.channel?.name ?? ""),
      position: props.threadTs
        ? "Thread"
        : props.isComposerPage
          ? "New message"
          : "Conversation",
      threadHistory: [],
    };
    if (!props.threadTs) return context;
    if (!props.channelId) throw new Error("The thread channel is unavailable.");
    let thread = threadSource(record, props);
    let messages = threadMessages(thread, props);
    if (!messages) {
      if (typeof thread.load !== "function") {
        throw new Error(
          "History loading is not supported in this thread view.",
        );
      }
      current.ui?.setStage("loading");
      let timeout: ReturnType<typeof setTimeout> | undefined;
      try {
        const result = await Promise.race([
          thread.load({
            channelId: props.channelId,
            threadTs: props.threadTs,
            latest: thread.rootMsg?.latest_reply,
            limit: 10,
            skipSubscriptionUpdate: true,
          }),
          new Promise<never>((_, reject) => {
            timeout = setTimeout(
              () =>
                reject(
                  new Error(
                    "Thread history loading timed out. Retry or send the original.",
                  ),
                ),
              10000,
            );
          }),
        ]);
        if (pending !== current) return;
        thread = threadSource(record, props);
        messages = threadMessages(
          thread,
          props,
          isRecord(result) && Array.isArray(result.msgs)
            ? result.msgs.map(readMessage)
            : [],
        );
      } catch (error) {
        throw new Error(
          `Could not load thread history: ${errorMessage(error)}`,
        );
      } finally {
        clearTimeout(timeout);
      }
      if (!messages)
        throw new Error(
          "The latest thread history is still incomplete. Retry or send the original.",
        );
    }
    context.threadHistory = messages.map((message, index) => {
      if (
        !message ||
        typeof message.text !== "string" ||
        (index && message.thread_ts !== props.threadTs)
      )
        throw new Error(
          "Thread message text is unavailable. Retry or send the original.",
        );
      const author =
        memberNameFor(record.element, message.user) ||
        message.bot_profile?.name ||
        message.username;
      if (!author)
        throw new Error(
          "A thread author's name is unavailable. Retry or send the original.",
        );
      return {
        position: index ? "Reply" : "Thread start",
        author,
        text: message.text,
      };
    });
    return context;
  }

  function snapshot(record: ComposerRecord): string {
    const input = inputFor(record);
    if (!record.element.isConnected || !input) {
      throw new Error("The composer is no longer available.");
    }
    const contents = readContents(input.getContents());
    if (!Array.isArray(contents?.contents)) {
      throw new Error("Unsupported Slack draft format.");
    }
    const props = { ...record.parent?.props, ...record.raw };
    return JSON.stringify({
      url: location.href,
      team: props.teamId,
      channel: props.channelId,
      thread: props.threadTs ?? null,
      destinations: props.draft?.destinations,
      contents,
      files: record.raw.draftComposerFiles,
      pendingFiles: props.pendingFileIds,
      hasFiles: props.hasFiles,
      gifUnfurls: props.hasGifUnfurls,
      blockUnfurls: props.hasBlockUnfurls,
      broadcast: record.parent?.state?.broadcast,
    });
  }

  function suggestionParts(text: string): string[] {
    return draftTools.parts(text);
  }

  function validSuggestion(
    current: PendingReview,
    text: unknown,
  ): text is string {
    return draftTools.valid(current.elements, text);
  }

  function readableSuggestion(current: PendingReview, text: string): string {
    return text.replace(
      /⟦SLACK_ELEMENT_[^⟧]*⟧/g,
      (token) =>
        current.elements.find((element) => element.token === token)?.label ??
        "[Unknown element]",
    );
  }

  function mountPanel(current: PendingReview): ReviewPanel {
    const editor = current.record.element;
    const container =
      editor.closest(".c-wysiwyg_container") ?? editor.parentElement;
    if (!container) throw new Error("The composer is no longer available.");
    const composer = container;
    const host = document.createElement("div");
    host.style.cssText = "position:fixed;z-index:2147483647;display:block";
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
      section { background: light-dark(#fffffff5,#202124f5); color: light-dark(#202124,#f0f0f0);
        border: 1px solid light-dark(#d7d9de,#505258); border-radius: 12px;
        box-shadow: 0 8px 32px #0003; padding: 14px; max-height: min(640px,80vh);
        display:flex; flex-direction:column; overflow:hidden; backdrop-filter: blur(16px); }
      .body { min-height:0; overflow:auto; }
      .status, .bottom { flex-shrink:0; }
      footer, .ask, .message-heading { display:flex; align-items:center; gap:8px; }
      .message-heading { justify-content:space-between; margin-bottom:5px; }
      .status { color:light-dark(#526476,#b5c7da); font-size:12px; }
      .busy .status::before { content:""; display:inline-block; width:10px; height:10px;
        border:2px solid #9daabc; border-top-color:transparent; border-radius:50%;
        margin-right:6px; animation:spin .8s linear infinite; }
      @keyframes spin { to { transform:rotate(360deg); } }
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
      button.primary { background:#007a5a; color:white; border-color:#007a5a; }
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
      button.primary:not(:disabled):hover { background:#00674c; }
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
            const list = node(
              ordered ? "ol" : "ul",
              "",
              current?.item ?? target,
            );
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
    const body = node("div", "", panel, "body");
    const errorMessage = node("div", "", body, "error");
    errorMessage.setAttribute("role", "alert");
    errorMessage.hidden = true;
    const assessmentPanel = node("div", "", body, "assessment");
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
    const previewHeading = node(
      "label",
      "Message preview",
      body,
      "preview-heading",
    );
    const preview = node("div", "", body, "preview");
    preview.setAttribute("role", "region");
    preview.setAttribute("aria-label", "Message preview");
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
    const retry = node("button", "Retry", footer);
    const check = node("button", "Check with AI", footer);
    const original = node("button", "Send original", footer);
    const revised = node("button", "Send suggestion", footer, "primary");
    const note = node("div", "", bottom, "note");

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
              item.attributes.link
                ? "a"
                : item.attributes.code
                  ? "code"
                  : "span",
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
            if (item.attributes.strike)
              run.style.textDecoration = "line-through";
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
        current.busy || current.applyFailed || !hasSuggestion || !valid;
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
          selected.length > 0 &&
            selected.every((line) => line.list === "bullet"),
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
        if (index < selectedLines.start || index > selectedLines.end)
          return line;
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
        suggestionError = undefined;
      } catch (error) {
        suggestionError =
          error instanceof Error ? error.message : String(error);
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
      original.textContent = confirming ? "Send" : "Send original";
      original.classList.toggle("primary", confirming);
      if (busy) status.hidden = false;
      ask.disabled = busy || current.phase !== "review";
      question.disabled = busy || current.phase !== "review";
      original.disabled = busy;
      revised.disabled =
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
      previewHeading.hidden = confirming;
      updateSuggestionState();
    }
    function setStage(stage: "loading" | "checking" | "review"): void {
      current.phase = stage;
      retry.hidden = true;
      errorMessage.hidden = true;
      status.textContent =
        stage === "loading"
          ? "Loading thread…"
          : stage === "checking"
            ? "Checking…"
            : "Reviewing…";
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
        pending !== current
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
        cancelPending();
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
    cancel.onclick = () => cancelPending();
    check.onclick = () => {
      if (pending !== current || current.busy || current.phase !== "confirm")
        return;
      current.turn++;
      beginStage(current, "review");
    };
    retry.onclick = () => {
      if (pending !== current || current.busy) return;
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
    const saved = new Map<Element, Map<string, string | null>>();
    function lock(element: Element, attribute: string, value: string): void {
      const attributes = saved.get(element) ?? new Map<string, string | null>();
      saved.set(element, attributes);
      if (!attributes.has(attribute))
        attributes.set(attribute, element.getAttribute(attribute));
      if (element.getAttribute(attribute) !== value)
        element.setAttribute(attribute, value);
    }
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
      lock(editor, "contenteditable", "false");
      for (const button of composer.querySelectorAll("button")) {
        lock(button, "disabled", "");
      }
      const rect = composer.getBoundingClientRect();
      const width = Math.min(520, Math.max(280, rect.width), innerWidth - 24);
      host.style.width = width + "px";
      host.style.left =
        Math.max(12, Math.min(rect.right - width, innerWidth - width - 12)) +
        "px";
      host.style.bottom = Math.max(12, innerHeight - rect.bottom) + "px";
      if (suggestion.clientWidth !== suggestionWidth) resizeSuggestion();
    }
    function guard(event: Event): void {
      if (!(event.target instanceof Node) || !composer.contains(event.target))
        return;
      event.preventDefault();
      event.stopImmediatePropagation();
    }
    for (const type of ["keydown", "beforeinput", "paste", "drop", "click"]) {
      window.addEventListener(type, guard, true);
    }
    document.body.append(host);
    setBusy(true);
    refresh();
    cancel.focus();
    return {
      refresh,
      setStage,
      classificationFailed,
      sendFailed(message) {
        setBusy(false);
        errorMessage.textContent = message;
        errorMessage.hidden = false;
        status.hidden = true;
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
        question.focus();
      },
      close() {
        host.remove();
        for (const type of [
          "keydown",
          "beforeinput",
          "paste",
          "drop",
          "click",
        ]) {
          window.removeEventListener(type, guard, true);
        }
        for (const [element, attributes] of saved) {
          for (const [attribute, value] of attributes) {
            if (value === null) element.removeAttribute(attribute);
            else element.setAttribute(attribute, value);
          }
        }
      },
    };
  }

  async function beginStage(
    current: PendingReview,
    stage: "checking" | "review",
  ): Promise<void> {
    if (pending !== current) return;
    if (stage === "review") current.initialStage = "review";
    try {
      if (snapshot(current.record) !== current.fingerprint) {
        cancelPending("Draft changed.");
        return;
      }
    } catch {
      cancelPending("Composer unavailable.");
      return;
    }
    current.ui?.setStage(stage);
    const turn = current.turn;
    if (!current.context) {
      try {
        const context = await contextFor(current);
        if (pending !== current || current.turn !== turn) return;
        if (snapshot(current.record) !== current.fingerprint) {
          cancelPending("Draft changed.");
          return;
        }
        if (!context) return;
        current.context = context;
      } catch (error) {
        if (pending !== current || current.turn !== turn) return;
        current.ui?.setStage("checking");
        current.ui?.classificationFailed(errorMessage(error));
        return;
      }
    }
    current.ui?.setStage(stage);
    try {
      notify({
        kind: stage === "checking" ? "classify" : "review",
        id: current.id,
        turn: current.turn,
        original:
          stage === "checking" ? current.original : current.reviewOriginal,
        protectedElements: current.elements.map(({ token, label, href }) => ({
          token,
          label,
          href,
        })),
        context: current.context,
      });
    } catch {
      const error =
        "Review connection unavailable. Cancel and restart the controller.";
      if (stage === "checking") current.ui?.classificationFailed(error);
      else current.ui?.receive({ error });
    }
  }

  function cancelPending(reason = "Review cancelled.") {
    if (!pending) {
      return;
    }
    const current = pending;
    pending = undefined;
    current.ui?.close();
    current.finish(null);
    try {
      notify({ kind: "cancel", id: current.id, reason });
    } catch {}
  }

  function intercept(
    record: ComposerRecord,
    args: unknown[],
  ): Promise<unknown> {
    if (stopped || pending) {
      return Promise.resolve(null);
    }
    let fingerprint: string;
    try {
      fingerprint = snapshot(record);
    } catch (error) {
      console.error("[Slack review] Send blocked:", errorMessage(error));
      return Promise.resolve(null);
    }
    const draft = readSnapshot(fingerprint);
    const original = draft.contents.contents
      .map((op) =>
        typeof op.insert === "string" ? op.insert : JSON.stringify(op.insert),
      )
      .join("")
      .replace(/\n$/, "");
    let projection: DraftProjection;
    try {
      if (!draftTools) throw new Error("Slack draft tools are unavailable.");
      projection = draftTools.capture(draft.contents.contents);
    } catch (error) {
      console.error(
        "[Slack review] Draft capture failed:",
        errorMessage(error),
      );
      return Promise.resolve(null);
    }
    const id = crypto.randomUUID();
    const hasAttachments = Boolean(
      draft.hasFiles ||
      ((isRecord(draft.files) || Array.isArray(draft.files)) &&
        Object.keys(draft.files).length) ||
      ((isRecord(draft.pendingFiles) || Array.isArray(draft.pendingFiles)) &&
        Object.keys(draft.pendingFiles).length) ||
      draft.gifUnfurls,
    );
    return new Promise<unknown>((finish) => {
      pending = {
        id,
        record,
        args,
        fingerprint,
        original,
        reviewOriginal: draftTools.serialize(projection.text, projection.lines),
        previewOriginal: projection.text,
        elements: projection.elements,
        projection,
        finish,
        turn: 0,
        busy: false,
        applyFailed: false,
        context: undefined,
        ui: undefined,
        phase: hasAttachments ? "review" : "checking",
        initialStage: hasAttachments ? "review" : "checking",
      };
      try {
        pending.ui = mountPanel(pending);
        void beginStage(pending, pending.initialStage);
      } catch {
        cancelPending();
      }
    });
  }

  function scan() {
    if (stopped) {
      return;
    }
    for (const element of document.querySelectorAll<HTMLElement>(
      '.ql-editor[contenteditable="true"]',
    )) {
      let instance: MessageInput | undefined;
      let parent: ComposerParent | undefined;
      for (const fiber of ancestors(element)) {
        if (
          displayName(fiber.stateNode) === "MessageInput" &&
          isMessageInput(fiber.stateNode)
        ) {
          instance = fiber.stateNode;
        }
        if (
          ["MessagePaneInput", "InputContainer"].includes(
            displayName(fiber.stateNode) ?? "",
          )
        ) {
          if (isParent(fiber.stateNode)) parent = fiber.stateNode;
          break;
        }
      }
      if (
        !instance ||
        (!parent && !instance.props.isComposerPage) ||
        records.has(instance)
      ) {
        continue;
      }
      const descriptor = Object.getOwnPropertyDescriptor(instance, "props");
      if (
        !descriptor?.configurable ||
        !descriptor.writable ||
        typeof instance.props.sendMessage !== "function"
      ) {
        continue;
      }
      const record: ComposerRecord = {
        instance,
        parent,
        element,
        descriptor,
        raw: instance.props,
        proxy: undefined,
      };
      const wrappedSend = (...args: unknown[]) => intercept(record, args);
      function updateProps(props: unknown): void {
        if (!isComposerProps(props))
          throw new Error("Unsupported Slack composer properties.");
        record.raw = props;
        record.proxy = new Proxy(props, {
          get(target, key, receiver) {
            return key === "sendMessage"
              ? wrappedSend
              : Reflect.get(target, key, receiver);
          },
        });
      }
      // React replaces props on render; wrap the shared callback before either send path reads it.
      updateProps(record.raw);
      Object.defineProperty(instance, "props", {
        configurable: true,
        enumerable: descriptor.enumerable ?? false,
        get: () => record.proxy,
        set: updateProps,
      });
      records.set(instance, record);
      notify({ kind: "attached", count: records.size });
    }
    if (pending) {
      try {
        pending.ui?.refresh();
        const latest = snapshot(pending.record);
        if (!pending.applyFailed && latest !== pending.fingerprint) {
          const before = readSnapshot(pending.fingerprint);
          const after = readSnapshot(latest);
          const fields = [
            ...new Set([...Object.keys(before), ...Object.keys(after)]),
          ].filter(
            (key) => JSON.stringify(before[key]) !== JSON.stringify(after[key]),
          );
          cancelPending(`Draft changed during review: ${fields.join(", ")}`);
        }
      } catch {
        cancelPending("Composer unavailable.");
      }
    }
    for (const [instance, record] of records) {
      if (!record.element.isConnected) {
        Object.defineProperty(instance, "props", {
          ...record.descriptor,
          value: record.raw,
        });
        records.delete(instance);
      }
    }
  }

  function preparePatch(
    current: PendingReview,
    text: string,
    lines?: DeltaAttributes[],
  ): DraftPatch {
    const input = inputFor(current.record);
    return draftTools.patch(
      current.projection,
      text,
      (html) => {
        const quill = input?.instance?.quill ?? input?.quill;
        if (
          typeof input?.convertSlackHTMLToDelta !== "function" ||
          typeof quill?.getFormat !== "function"
        ) {
          throw new Error(
            "This Slack editor does not support list conversion.",
          );
        }
        const descriptor = Object.getOwnPropertyDescriptor(quill, "getFormat");
        // Neutralize cursor formatting only during the synchronous clipboard conversion.
        Object.defineProperty(quill, "getFormat", {
          configurable: true,
          value: () => ({}),
        });
        try {
          const converted = input.convertSlackHTMLToDelta(html);
          if (!isRecord(converted))
            throw new Error("Unsupported Slack list contents.");
          return { ops: readOps(converted.ops) };
        } finally {
          if (descriptor) Object.defineProperty(quill, "getFormat", descriptor);
          else delete quill.getFormat;
        }
      },
      lines,
    );
  }

  function resolve(
    id: string,
    decision:
      | { action: "cancel" }
      | { action: "original"; text: string }
      | { action: "revised"; text: string; patch: DraftPatch },
  ): string {
    if (!pending || pending.id !== id) {
      return "expired";
    }
    const current = pending;
    if (current.busy) return "busy";
    const { record } = current;
    if (decision.action === "cancel") {
      cancelPending();
      return "cancelled";
    }
    if (current.applyFailed) return "apply-failed";
    try {
      if (
        snapshot(record) !== current.fingerprint ||
        !["original", "revised"].includes(decision.action) ||
        typeof decision.text !== "string" ||
        (decision.action === "revised" &&
          (!validSuggestion(current, decision.text) ||
            decision.patch.text !== decision.text)) ||
        (decision.action === "original" && decision.text !== current.original)
      ) {
        cancelPending();
        return "changed-or-invalid";
      }
    } catch {
      cancelPending();
      return "composer-unavailable";
    }
    if (decision.action === "revised") {
      let applied = false;
      try {
        const input = inputFor(record);
        if (typeof input?.updateContents !== "function") {
          throw new Error(
            "This Slack editor does not support formatted updates.",
          );
        }
        const patch = decision.patch;
        applied = true;
        input.updateContents({ contents: patch.contents });
        const latest = readSnapshot(snapshot(record));
        const before = readSnapshot(current.fingerprint);
        if (
          !draftTools.matches(latest.contents.contents, patch.expected) ||
          Object.keys(before).some(
            (key) =>
              key !== "contents" &&
              JSON.stringify(before[key]) !== JSON.stringify(latest[key]),
          )
        ) {
          throw new Error("Slack did not preserve the expected draft.");
        }
      } catch (error) {
        current.applyFailed = applied;
        current.ui?.sendFailed(
          `${errorMessage(error)} Nothing was sent.${applied ? " Cancel and inspect the draft in Slack." : ""}`,
        );
        return "apply-failed";
      }
    }
    pending = undefined;
    current.ui?.close();
    try {
      notify({ kind: "cancel", id: current.id, reason: "Review finished." });
    } catch {}
    try {
      // Call Slack once; its own sending, warnings, and failure recovery remain responsible for delivery.
      current.finish(
        Reflect.apply(record.raw.sendMessage, record.raw, current.args),
      );
      return "handed-to-slack";
    } catch (error) {
      current.finish(null);
      console.error(
        "[Slack review] Slack send callback failed:",
        errorMessage(error),
      );
      return "send-error";
    }
  }

  window.__slackMessageReview = {
    owner,
    pulse(id) {
      if (id !== owner) return false;
      lastPulse = Date.now();
      return true;
    },
    receive(id, turn, result) {
      if (
        pending?.id !== id ||
        pending.turn !== turn ||
        pending.phase !== "review"
      )
        return;
      pending.ui?.receive(result);
    },
    receiveClassification(id, turn, result) {
      if (
        pending?.id !== id ||
        pending.turn !== turn ||
        pending.phase !== "checking"
      )
        return;
      const current = pending;
      if ("error" in result) {
        current.ui?.classificationFailed(result.error);
      } else if (
        result.choice === "simple_reply" ||
        result.choice === "link_share"
      ) {
        current.ui?.confirm();
      } else if (result.choice === "review") {
        beginStage(current, "review");
      } else {
        current.ui?.classificationFailed(
          "Jev returned an invalid message type.",
        );
      }
    },
    stop() {
      stopped = true;
      cancelPending();
      clearInterval(timer);
      window.removeEventListener("keydown", scan, true);
      window.removeEventListener("click", scan, true);
      for (const [instance, record] of records) {
        Object.defineProperty(instance, "props", {
          ...record.descriptor,
          value: record.raw,
        });
      }
      records.clear();
      delete window.__slackMessageReview;
    },
  };
  window.addEventListener("keydown", scan, true);
  window.addEventListener("click", scan, true);
  // Release the composer even if the controller exits without running cleanup.
  const timer = setInterval(() => {
    if (Date.now() - lastPulse > 15000) {
      window.__slackMessageReview?.stop();
      return;
    }
    scan();
  }, 300);
  scan();
})();
