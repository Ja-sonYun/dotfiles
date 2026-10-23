(() => {
  if (window !== window.top || location.origin !== "https://app.slack.com")
    return;
  if (window.__slackThreadSummary)
    throw new Error("A thread summary controller is already attached.");
  const owner = "@controllerId@";
  const records = new Map();
  const requests = new Map();
  const tasks = new Map();
  const createTimeline = /* @timeline@ */ null;
  const timeline = createTimeline({
    ancestors,
    keyFor,
    retrySave,
    deleteCard,
    memberName,
  });
  let lastPulse = Date.now();
  let stopped = false;

  function notify(message) {
    window.__slackThreadSummaryBridge(JSON.stringify(message));
  }

  function ancestors(element) {
    let fiber;
    for (let node = element; node && !fiber; node = node.parentElement) {
      const key = Object.keys(node).find((name) =>
        name.startsWith("__reactFiber$"),
      );
      if (key) fiber = node[key];
    }
    const result = [];
    for (; fiber; fiber = fiber.return) result.push(fiber);
    return result;
  }

  function identity(record) {
    const props = record.instance.props;
    return JSON.stringify([
      props.teamId,
      props.channelId,
      props.threadTs,
      location.href,
    ]);
  }

  function keyFor(thread) {
    return JSON.stringify([thread.teamId, thread.channelId, thread.threadTs]);
  }

  function memberName(record, id) {
    const props = ancestors(record.element)
      .map((fiber) => fiber.stateNode?.props ?? fiber.memoizedProps)
      .find((candidate) => typeof candidate?.getMember === "function");
    const member = props?.getMember(id);
    return (
      member?.profile?.display_name ||
      member?.profile?.real_name ||
      member?.real_name ||
      member?.name
    );
  }

  function showTask(record) {
    const task = tasks.get(keyFor(record.thread));
    record.task = task;
    if (!task) return;
    if (task.error) record.ui.fail(task.error);
    else {
      record.ui.open();
      record.ui.progress(task.progress);
    }
  }

  function request(record, kind, fields = {}) {
    const id = crypto.randomUUID();
    return new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        requests.delete(id);
        try {
          notify({ kind: "cancel", id });
        } catch {}
        reject(new Error("Summary storage request timed out. Retry."));
      }, 20000);
      requests.set(id, { record, resolve, reject, timeout });
      try {
        notify({ kind, id, thread: record.thread, ...fields });
      } catch (error) {
        clearTimeout(timeout);
        requests.delete(id);
        reject(error);
      }
    });
  }

  async function loadSaved(record) {
    try {
      const result = await request(record, "load");
      if (result.job) attachJob(record.thread, result.job);
      record.ui.historyError("");
    } catch (error) {
      if (records.get(record.instance) === record)
        record.ui.historyError(error.message);
    }
  }

  function attachJob(thread, job) {
    const key = keyFor(thread);
    const task = tasks.get(key);
    if (task?.id !== job.id) {
      tasks.set(key, {
        id: job.id,
        thread,
        phase: "summarizing",
        controller: new AbortController(),
        progress: job.progress,
      });
    }
    for (const record of records.values()) {
      if (keyFor(record.thread) === key) showTask(record);
    }
  }

  async function retrySave(thread, cardId) {
    const record = [...records.values()].find(
      (item) => keyFor(item.thread) === keyFor(thread),
    );
    if (!record)
      throw new Error("Open this thread to retry saving its summary.");
    const result = await request(record, "save", { cardId });
    if (result.saveError) throw new Error(result.saveError);
  }

  async function deleteCard(thread, cardId) {
    const record = [...records.values()].find(
      (item) => keyFor(item.thread) === keyFor(thread),
    );
    if (!record) throw new Error("Open this thread to delete its summary.");
    await request(record, "delete", { cardId });
  }

  function threadSource(record) {
    const props = record.instance.props;
    const candidates = ancestors(record.element);
    for (const panel of document.querySelectorAll(
      '[data-qa="threads_flexpane"], .p-threads_flexpane_container',
    )) {
      candidates.push(...ancestors(panel));
    }
    for (const fiber of candidates) {
      const candidate = fiber.stateNode?.props ?? fiber.memoizedProps;
      const thread = candidate?.threads?.find?.(
        (item) =>
          item.channelId === props.channelId &&
          item.threadTs === props.threadTs,
      );
      if (thread)
        return {
          ...thread,
          rootMsg: thread.messages?.[props.threadTs],
          load: candidate.requestReplies,
        };
      if (
        candidate?.rootMsg &&
        candidate.channelId === props.channelId &&
        candidate.threadTs === props.threadTs &&
        Array.isArray(candidate.timestamps)
      ) {
        return { ...candidate, load: candidate.requestHistory };
      }
    }
    throw new Error(
      "This thread view does not expose its history. Open the thread in the side panel and retry.",
    );
  }

  function metadata(source, threadTs) {
    const root = source.rootMsg;
    const count = root?.reply_count ?? (!root?.latest_reply ? 0 : undefined);
    if (
      root?.ts !== threadTs ||
      !Number.isInteger(count) ||
      count < 0 ||
      (count > 0 && typeof root.latest_reply !== "string")
    ) {
      throw new Error("Thread metadata is unavailable. Retry.");
    }
    return { count, latest: root.latest_reply ?? null };
  }

  function assertCurrent(record, task) {
    task.controller.signal.throwIfAborted();
    if (
      record.task !== task ||
      !record.element.isConnected ||
      identity(record) !== record.identity
    ) {
      throw new Error("The thread is no longer active.");
    }
  }

  async function loadPage(load, args, signal) {
    signal.throwIfAborted();
    let timeout;
    let abort;
    try {
      return await Promise.race([
        Promise.resolve().then(() => {
          signal.throwIfAborted();
          return load(args);
        }),
        new Promise((_, reject) => {
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
      signal.removeEventListener("abort", abort);
    }
  }

  async function collect(record, task) {
    const props = record.instance.props;
    let source = threadSource(record);
    const initial = metadata(source, props.threadTs);
    const replies = new Map();
    function add(messages) {
      for (const message of messages) {
        if (
          message?.thread_ts === props.threadTs &&
          message.ts !== props.threadTs &&
          typeof message.ts === "string" &&
          message.ts <= initial.latest &&
          (!message.channel || message.channel === props.channelId)
        )
          replies.set(message.ts, message);
      }
    }
    add(source.timestamps.map((ts) => source.messages?.[ts]));
    let latest = initial.latest;
    while (replies.size < initial.count) {
      assertCurrent(record, task);
      if (typeof source.load !== "function")
        throw new Error("History loading is unavailable in this thread view.");
      record.ui.progress(
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
      const page = result?.msgs;
      if (!Array.isArray(page))
        throw new Error("Slack returned incomplete thread history. Retry.");
      add(page);
      const oldest = page
        .filter(
          (message) =>
            message?.thread_ts === props.threadTs &&
            message.ts !== props.threadTs &&
            typeof message.ts === "string" &&
            message.ts <= latest &&
            (!message.channel || message.channel === props.channelId),
        )
        .map((message) => message.ts)
        .sort()[0];
      if (replies.size < initial.count && (!oldest || oldest >= latest)) {
        throw new Error(
          "Slack did not return the complete thread history. Retry.",
        );
      }
      latest = oldest;
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
      if (typeof message.text !== "string")
        throw new Error("A thread message has no readable text. Retry.");
      const author =
        (message.user && memberName(record, message.user)) ||
        message.bot_profile?.name ||
        message.username;
      if (!author)
        throw new Error("A thread author's name is unavailable. Retry.");
      const mentions = {};
      for (const match of message.text.matchAll(
        /<@([A-Z0-9]+)(?:\|[^>]+)?>/g,
      )) {
        const name = memberName(record, match[1]);
        if (name) mentions[match[1]] = name;
      }
      return { author, text: message.text, mentions };
    });
    const location = {
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

  function cancel(record) {
    const task = record.task;
    if (!task) return;
    record.task = undefined;
    tasks.delete(keyFor(record.thread));
    task.controller.abort();
    for (const attached of records.values()) {
      if (keyFor(attached.thread) !== keyFor(record.thread)) continue;
      attached.task = undefined;
      attached.ui.receive({});
    }
    try {
      notify({ kind: "cancel", id: task.id });
    } catch {}
  }

  async function begin(record) {
    const existing = tasks.get(keyFor(record.thread));
    if (stopped || (existing && !existing.error)) return;
    const task = {
      id: crypto.randomUUID(),
      controller: new AbortController(),
      thread: record.thread,
      phase: "loading",
      progress: "Loading thread…",
    };
    tasks.set(keyFor(record.thread), task);
    for (const attached of records.values()) {
      if (keyFor(attached.thread) === keyFor(record.thread)) showTask(attached);
    }
    try {
      assertCurrent(record, task);
      const input = await collect(record, task);
      assertCurrent(record, task);
      task.phase = "summarizing";
      task.progress = `Summarizing ${input.messages.length} messages…`;
      record.ui.progress(task.progress);
      notify({
        kind: "summarize",
        id: task.id,
        thread: record.thread,
        ...input,
      });
    } catch (error) {
      if (record.task !== task || task.controller.signal.aborted) return;
      task.error = error.message;
      record.ui.fail(error.message);
    }
  }

  function mount(record) {
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
    function node(tag, text, parent, className) {
      const element = document.createElement(tag);
      element.textContent = text;
      if (tag === "button") element.type = "button";
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
    function busy(value) {
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
        if (record.task?.phase === "loading" && !record.task.error) {
          record.task.error = "Thread loading was interrupted. Retry.";
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
        !record.ui.host.isConnected ||
        identity(record) !== record.identity
      ) {
        record.ui.remove();
        records.delete(instance);
      }
    }
    for (const element of document.querySelectorAll(".ql-editor")) {
      const instance = ancestors(element)
        .map((fiber) => fiber.stateNode)
        .find((value) => value?.constructor?.displayName === "MessageInput");
      if (!instance?.props.threadTs || records.has(instance)) continue;
      const anchor = element.closest('[data-qa="reply_container"]');
      if (!anchor || element.closest(".c-wysiwyg_container")?.contains(anchor))
        continue;
      const record = { instance, element, anchor, task: undefined };
      record.thread = {
        teamId: instance.props.teamId,
        channelId: instance.props.channelId,
        threadTs: instance.props.threadTs,
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
        task.progress = result.progress;
        for (const record of attached) showTask(record);
        return;
      }
      if (result.error) {
        task.error = result.error;
        for (const record of attached) showTask(record);
      } else {
        tasks.delete(keyFor(task.thread));
        timeline.merge(task.thread, result.cards ?? []);
        timeline.scan(records.values());
        for (const record of attached) {
          record.task = undefined;
          record.ui.receive(result);
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
      for (const record of records.values()) record.ui.remove();
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
