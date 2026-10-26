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

  function isSummaryInstance(value: unknown): value is SummaryInstance {
    if (!isRecord(value) || !isRecord(value.props)) return false;
    try {
      const props = slackProps(value.props);
      return (
        typeof props.teamId === "string" &&
        typeof props.channelId === "string" &&
        typeof props.threadTs === "string"
      );
    } catch {
      return false;
    }
  }

  if (window !== window.top || location.origin !== "https://app.slack.com")
    return;
  if (window.__slackThreadSummary)
    throw new Error("A thread summary controller is already attached.");
  const owner = "@controllerId@";
  const records = new Map<SummaryInstance, SummaryRecord>();
  const requests = new Map<string, StorageRequest>();
  const tasks = new Map<string, SummaryTask>();
  // The controller substitutes the compiled timeline factory before injection.
  const createTimeline = /* @timeline@ */ null as TimelineFactory | null;
  if (!createTimeline)
    throw new Error("Slack timeline tools were not installed.");
  const timeline = createTimeline({
    ancestors,
    fiberProps,
    keyFor,
    retrySave,
    deleteCard,
    memberName,
  });
  let lastPulse = Date.now();
  let stopped = false;

  function notify(message: SummaryRequest): void {
    window.__slackThreadSummaryBridge(JSON.stringify(message));
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

  function identity(record: SummaryRecord): string {
    const props = record.instance.props;
    return JSON.stringify([
      props.teamId,
      props.channelId,
      props.threadTs,
      location.href,
    ]);
  }

  function keyFor(thread: ThreadIdentity): string {
    return JSON.stringify([thread.teamId, thread.channelId, thread.threadTs]);
  }

  function memberName(
    record: SummaryRecord,
    id: string | undefined,
  ): string | undefined {
    return memberNameFor(record.element, id);
  }

  function showTask(record: SummaryRecord): void {
    const task = tasks.get(keyFor(record.thread));
    record.task = task;
    if (!task) return;
    if (task.state.phase === "failed") record.ui?.fail(task.state.error);
    else {
      record.ui?.open();
      record.ui?.progress(task.state.progress);
    }
  }

  function request(
    record: SummaryRecord,
    operation: { kind: "load" } | { kind: "save" | "delete"; cardId: string },
  ): Promise<SummaryResult> {
    const id = crypto.randomUUID();
    return new Promise<SummaryResult>((resolve, reject) => {
      const timeout = setTimeout(() => {
        requests.delete(id);
        try {
          notify({ kind: "cancel", id });
        } catch {}
        reject(new Error("Summary storage request timed out. Retry."));
      }, 20000);
      requests.set(id, { record, resolve, reject, timeout });
      try {
        notify({ ...operation, id, thread: record.thread });
      } catch (error) {
        clearTimeout(timeout);
        requests.delete(id);
        reject(error);
      }
    });
  }

  async function loadSaved(record: SummaryRecord): Promise<void> {
    try {
      const result = await request(record, { kind: "load" });
      if (result.job) attachJob(record.thread, result.job);
      record.ui?.historyError("");
    } catch (error) {
      if (records.get(record.instance) === record)
        record.ui?.historyError(errorMessage(error));
    }
  }

  function attachJob(thread: ThreadIdentity, job: SummaryJob): void {
    const key = keyFor(thread);
    const task = tasks.get(key);
    if (task?.id !== job.id) {
      tasks.set(key, {
        id: job.id,
        thread,
        controller: new AbortController(),
        state: { phase: "summarizing", progress: job.progress },
      });
    }
    for (const record of records.values()) {
      if (keyFor(record.thread) === key) showTask(record);
    }
  }

  async function retrySave(
    thread: ThreadIdentity,
    cardId: string,
  ): Promise<void> {
    const record = [...records.values()].find(
      (item) => keyFor(item.thread) === keyFor(thread),
    );
    if (!record)
      throw new Error("Open this thread to retry saving its summary.");
    const result = await request(record, { kind: "save", cardId });
    if (result.saveError) throw new Error(result.saveError);
  }

  async function deleteCard(
    thread: ThreadIdentity,
    cardId: string,
  ): Promise<void> {
    const record = [...records.values()].find(
      (item) => keyFor(item.thread) === keyFor(thread),
    );
    if (!record) throw new Error("Open this thread to delete its summary.");
    await request(record, { kind: "delete", cardId });
  }

  function threadSource(record: SummaryRecord): ThreadSource {
    const props = record.instance.props;
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
        const root = isRecord(thread.messages)
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
      "This thread view does not expose its history. Open the thread in the side panel and retry.",
    );
  }

  function metadata(
    source: ThreadSource,
    threadTs: string,
  ): { count: number; latest: string | null } {
    const root = source.rootMsg;
    const count = root?.reply_count ?? (!root?.latest_reply ? 0 : undefined);
    if (
      !root ||
      root.ts !== threadTs ||
      typeof count !== "number" ||
      !Number.isInteger(count) ||
      count < 0 ||
      (count > 0 && typeof root.latest_reply !== "string")
    ) {
      throw new Error("Thread metadata is unavailable. Retry.");
    }
    return { count, latest: root.latest_reply ?? null };
  }

  function assertCurrent(record: SummaryRecord, task: SummaryTask): void {
    task.controller.signal.throwIfAborted();
    if (
      record.task !== task ||
      !record.element.isConnected ||
      identity(record) !== record.identity
    ) {
      throw new Error("The thread is no longer active.");
    }
  }

  async function loadPage(
    load: LoadHistory,
    args: HistoryArgs,
    signal: AbortSignal,
  ): Promise<unknown> {
    signal.throwIfAborted();
    let timeout: ReturnType<typeof setTimeout> | undefined;
    let abort: (() => void) | undefined;
    try {
      return await Promise.race([
        Promise.resolve().then(() => {
          signal.throwIfAborted();
          return load(args);
        }),
        new Promise<never>((_, reject) => {
          abort = () => reject(new Error("Summary cancelled."));
          signal.addEventListener("abort", abort, { once: true });
          timeout = setTimeout(
            () => reject(new Error("Thread history loading timed out. Retry.")),
            10000,
          );
        }),
      ]);
    } finally {
      clearTimeout(timeout);
      if (abort) signal.removeEventListener("abort", abort);
    }
  }

  async function collect(
    record: SummaryRecord,
    task: SummaryTask,
  ): Promise<{
    messages: ThreadMessage[];
    location: ThreadLocation;
    throughTs: string;
  }> {
    const props = record.instance.props;
    let source = threadSource(record);
    const initial = metadata(source, props.threadTs);
    const replies = new Map<string, SlackMessage>();
    function add(messages: (SlackMessage | undefined)[]): void {
      for (const message of messages) {
        if (
          message !== undefined &&
          message.thread_ts === props.threadTs &&
          message.ts !== props.threadTs &&
          typeof message.ts === "string" &&
          initial.latest !== null &&
          message.ts <= initial.latest &&
          (!message.channel || message.channel === props.channelId)
        )
          replies.set(message.ts, message);
      }
    }
    add(source.timestamps.map((ts) => source.messages?.[ts]));
    let latest: string | null = initial.latest;
    while (replies.size < initial.count) {
      assertCurrent(record, task);
      if (typeof source.load !== "function")
        throw new Error("History loading is unavailable in this thread view.");
      record.ui?.progress(
        `Loading ${replies.size + 1} / ${initial.count + 1} messages…`,
      );
      const result = await loadPage(
        source.load,
        {
          channelId: props.channelId,
          threadTs: props.threadTs,
          latest,
          limit: 100,
          skipSubscriptionUpdate: true,
        },
        task.controller.signal,
      );
      assertCurrent(record, task);
      source = threadSource(record);
      if (
        JSON.stringify(metadata(source, props.threadTs)) !==
        JSON.stringify(initial)
      ) {
        throw new Error(
          "The thread changed while loading. Retry to include the latest messages.",
        );
      }
      const rawPage = isRecord(result) ? result.msgs : undefined;
      if (!Array.isArray(rawPage))
        throw new Error("Slack returned incomplete thread history. Retry.");
      const page = rawPage.map(readMessage);
      add(page);
      const oldest = page
        .filter(
          (message): message is SlackMessage =>
            message !== undefined &&
            message.thread_ts === props.threadTs &&
            message.ts !== props.threadTs &&
            typeof message.ts === "string" &&
            latest !== null &&
            message.ts <= latest &&
            (!message.channel || message.channel === props.channelId),
        )
        .map((message) => message.ts)
        .sort()[0];
      if (
        replies.size < initial.count &&
        (!oldest || latest === null || oldest >= latest)
      ) {
        throw new Error(
          "Slack did not return the complete thread history. Retry.",
        );
      }
      latest = oldest ?? null;
    }
    assertCurrent(record, task);
    source = threadSource(record);
    const sorted = [...replies.values()].sort((a, b) =>
      a.ts.localeCompare(b.ts),
    );
    if (
      JSON.stringify(metadata(source, props.threadTs)) !==
        JSON.stringify(initial) ||
      sorted.length !== initial.count ||
      (initial.count && sorted.at(-1)?.ts !== initial.latest)
    ) {
      throw new Error("The thread history changed or is incomplete. Retry.");
    }
    const messages = [source.rootMsg, ...sorted].map((message) => {
      if (!message || typeof message.text !== "string")
        throw new Error("A thread message has no readable text. Retry.");
      const author =
        (message.user && memberName(record, message.user)) ||
        message.bot_profile?.name ||
        message.username;
      if (!author)
        throw new Error("A thread author's name is unavailable. Retry.");
      const mentions: Record<string, string> = {};
      for (const match of message.text.matchAll(
        /<@([A-Z0-9]+)(?:\|[^>]+)?>/g,
      )) {
        const id = match[1];
        if (!id) continue;
        const name = memberName(record, id);
        if (name) mentions[id] = name;
      }
      return { author, text: message.text, mentions };
    });
    const location: ThreadLocation = {
      workspace:
        document
          .querySelector('[data-qa="workspace_actions_button"]')
          ?.textContent?.trim() ||
        document
          .querySelector('[data-qa="team-icon"]')
          ?.getAttribute("aria-label") ||
        "",
      conversation: props.channelDisplayName ?? props.channel?.name ?? "",
      position: "Thread",
    };
    return { messages, location, throughTs: initial.latest ?? props.threadTs };
  }

  function cancel(record: SummaryRecord): void {
    const task = record.task;
    if (!task) return;
    record.task = undefined;
    tasks.delete(keyFor(record.thread));
    task.controller.abort();
    for (const attached of records.values()) {
      if (keyFor(attached.thread) !== keyFor(record.thread)) continue;
      attached.task = undefined;
      attached.ui?.receive({});
    }
    try {
      notify({ kind: "cancel", id: task.id });
    } catch {}
  }

  async function begin(record: SummaryRecord): Promise<void> {
    const existing = tasks.get(keyFor(record.thread));
    if (stopped || (existing && existing.state.phase !== "failed")) return;
    const task: SummaryTask = {
      id: crypto.randomUUID(),
      controller: new AbortController(),
      thread: record.thread,
      state: { phase: "loading", progress: "Loading thread…" },
    };
    tasks.set(keyFor(record.thread), task);
    for (const attached of records.values()) {
      if (keyFor(attached.thread) === keyFor(record.thread)) showTask(attached);
    }
    try {
      assertCurrent(record, task);
      const input = await collect(record, task);
      assertCurrent(record, task);
      task.state = {
        phase: "summarizing",
        progress: `Summarizing ${input.messages.length} messages…`,
      };
      record.ui?.progress(task.state.progress);
      notify({
        kind: "summarize",
        id: task.id,
        thread: record.thread,
        ...input,
      });
    } catch (error) {
      if (record.task !== task || task.controller.signal.aborted) return;
      task.state = { phase: "failed", error: errorMessage(error) };
      record.ui?.fail(errorMessage(error));
    }
  }

  function mount(record: SummaryRecord): SummaryPanel {
    const host = document.createElement("div");
    host.style.cssText = "display:block;margin:8px 0";
    const root = host.attachShadow({ mode: "open" });
    for (const name of ["click", "keydown", "keyup"]) {
      root.addEventListener(name, (event) => event.stopPropagation());
    }
    const style = document.createElement("style");
    style.textContent = `
      :host { color-scheme:light dark; color:light-dark(#1d1c1d,#e8e8e8); font:13px/1.5 system-ui,sans-serif; }
      [hidden] { display:none !important; }
      button { font:inherit; color:inherit; background:light-dark(#f5f5f5,#303235); border:1px solid light-dark(#ddd,#555);
        border-radius:6px; padding:4px 9px; cursor:pointer; }
      button:disabled { opacity:.5; cursor:default; }
      .bar { display:flex; align-items:center; flex-wrap:wrap; gap:8px; }
      .status { color:light-dark(#65666a,#afb2b8); font-size:12px; }
      .busy::before { content:""; display:inline-block; width:10px; height:10px; margin-right:6px;
        border:2px solid #9daabc; border-top-color:transparent; border-radius:50%; animation:spin .8s linear infinite; }
      @keyframes spin { to { transform:rotate(360deg); } }
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
    const bar = node("div", "", root, "bar");
    const trigger = node("button", "Summarize thread", bar);
    const status = node("span", "", bar, "status");
    status.setAttribute("role", "status");
    const cancelButton = node("button", "Cancel", bar);
    const retry = node("button", "Retry", bar);
    const history = node("div", "", root, "error");
    const historyText = node("span", "", history);
    const historyRetry = node("button", "Retry loading summaries", history);
    const placement = node("div", "", root, "error");
    cancelButton.hidden = true;
    retry.hidden = true;
    history.hidden = true;
    function busy(value: boolean): void {
      trigger.disabled = value;
      cancelButton.hidden = !value;
      status.classList.toggle("busy", value);
    }
    trigger.onclick = () => void begin(record);
    retry.onclick = trigger.onclick;
    historyRetry.onclick = () => void loadSaved(record);
    cancelButton.onclick = () => {
      cancel(record);
      busy(false);
      status.textContent = "";
    };
    record.anchor.prepend(host);
    return {
      host,
      open() {
        retry.hidden = true;
        busy(true);
      },
      progress(text) {
        status.textContent = text;
      },
      fail(error) {
        busy(false);
        status.textContent = error;
        retry.hidden = false;
      },
      receive(result) {
        busy(false);
        retry.hidden = true;
        status.textContent = result.saveError ?? "";
      },
      historyError(error) {
        history.hidden = !error;
        historyText.textContent = error ?? "";
      },
      placementError(error) {
        placement.textContent = error;
      },
      remove() {
        if (record.task?.state.phase === "loading") {
          record.task.state = {
            phase: "failed",
            error: "Thread loading was interrupted. Retry.",
          };
          record.task.controller.abort();
        }
        for (const [id, pending] of requests) {
          if (pending.record !== record) continue;
          clearTimeout(pending.timeout);
          requests.delete(id);
          pending.reject(new Error("The thread is no longer active."));
          try {
            notify({ kind: "cancel", id });
          } catch {}
        }
        host.remove();
      },
    };
  }

  function scan() {
    if (stopped) return;
    for (const [instance, record] of records) {
      if (
        !record.element.isConnected ||
        !record.ui?.host.isConnected ||
        identity(record) !== record.identity
      ) {
        record.ui?.remove();
        records.delete(instance);
      }
    }
    for (const element of document.querySelectorAll<HTMLElement>(
      ".ql-editor",
    )) {
      const instance = ancestors(element)
        .map((fiber) => fiber.stateNode)
        .find(
          (value): value is SummaryInstance =>
            displayName(value) === "MessageInput" && isSummaryInstance(value),
        );
      if (!instance?.props.threadTs || records.has(instance)) continue;
      const anchor = element.closest('[data-qa="reply_container"]');
      if (!anchor || element.closest(".c-wysiwyg_container")?.contains(anchor))
        continue;
      const thread = {
        teamId: instance.props.teamId,
        channelId: instance.props.channelId,
        threadTs: instance.props.threadTs,
      };
      const record: SummaryRecord = {
        instance,
        element,
        anchor,
        task: undefined,
        thread,
        identity: "",
        ui: undefined,
      };
      record.identity = identity(record);
      record.ui = mount(record);
      records.set(instance, record);
      showTask(record);
      void loadSaved(record);
    }
    timeline.scan(records.values());
  }

  window.__slackThreadSummary = {
    owner,
    pulse(id) {
      if (id !== owner) return false;
      lastPulse = Date.now();
      return true;
    },
    receive(id, result) {
      const pending = requests.get(id);
      if (pending) {
        clearTimeout(pending.timeout);
        requests.delete(id);
        if (
          records.get(pending.record.instance) !== pending.record ||
          identity(pending.record) !== pending.record.identity
        ) {
          pending.reject(new Error("The thread is no longer active."));
          return;
        }
        if (result.error) pending.reject(new Error(result.error));
        else {
          timeline.merge(
            pending.record.thread,
            result.cards ?? [],
            result.deletedIds ?? [],
          );
          timeline.scan(records.values());
          pending.resolve(result);
        }
        return;
      }
      const task = [...tasks.values()].find((task) => task.id === id);
      if (!task) return;
      if (result.job) {
        attachJob(task.thread, result.job);
        return;
      }
      const attached = [...records.values()].filter(
        (record) => keyFor(record.thread) === keyFor(task.thread),
      );
      if (result.progress) {
        task.state = { phase: "summarizing", progress: result.progress };
        for (const record of attached) showTask(record);
        return;
      }
      if (result.error) {
        task.state = { phase: "failed", error: result.error };
        for (const record of attached) showTask(record);
      } else {
        tasks.delete(keyFor(task.thread));
        timeline.merge(task.thread, result.cards ?? []);
        timeline.scan(records.values());
        for (const record of attached) {
          record.task = undefined;
          record.ui?.receive(result);
        }
      }
    },
    receiveCards(thread, cards, deletedIds = []) {
      timeline.merge(thread, cards, deletedIds);
      timeline.scan(records.values());
    },
    stop() {
      stopped = true;
      clearInterval(timer);
      for (const record of records.values()) record.ui?.remove();
      for (const task of tasks.values()) {
        task.controller.abort();
        try {
          notify({ kind: "cancel", id: task.id });
        } catch {}
      }
      tasks.clear();
      records.clear();
      timeline.stop();
      delete window.__slackThreadSummary;
    },
  };
  const timer = setInterval(() => {
    if (Date.now() - lastPulse > 15000) {
      window.__slackThreadSummary?.stop();
      return;
    }
    scan();
  }, 300);
  scan();
})();
