(() => {
  const navigate = /* @navigation@ */ null as
    typeof navigateToConversation | null;
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
  const selectedWorkspace: string | null = /* @workspaceId@ */ null;
  const disableSend: boolean = /* @disableSend@ */ false;
  const ignoreConversations: string[] = /* @ignoreConversations@ */ [];
  // The controller substitutes the compiled draft factory before injection.
  const injectedDraft = /* @draft@ */ null as DraftTools | null;
  if (!injectedDraft) throw new Error("Slack draft tools were not installed.");
  const draftTools = injectedDraft;
  let lastPulse = Date.now();
  const records = new Map<MessageInput, ComposerRecord>();
  const pendingReviews = new Map<string, PendingReview>();
  const restored = new Map<string, StoredReviewSnapshot>();
  const saveQueue = new Map<string, Promise<void>>();
  const saves = new Map<
    string,
    { turn: number; resolve(): void; reject(error: Error): void }
  >();
  function saveReview(
    current: PendingReview,
    status: StoredReviewSnapshot["status"],
  ): Promise<void> {
    const snapshot: StoredReviewSnapshot = {
      id: current.id,
      workspaceId: current.workspaceId,
      destination: current.destination,
      fingerprint: current.fingerprint,
      original: current.original,
      reviewOriginal: current.reviewOriginal,
      previewOriginal: current.previewOriginal,
      projection: current.projection,
      turn: current.turn,
      phase: current.phase,
      status,
      result: current.result,
      context: current.context,
      startedAt: current.startedAt,
      location: current.location,
    };
    const job = (saveQueue.get(current.id) ?? Promise.resolve())
      .catch(() => {})
      .then(
        () =>
          new Promise<void>((resolve, reject) => {
            const timer = setTimeout(() => {
              saves.delete(current.id);
              reject(
                new Error(
                  "Draft could not be saved. Nothing was sent. Retry the review.",
                ),
              );
            }, 10000);
            saves.set(current.id, {
              turn: snapshot.turn,
              resolve() {
                clearTimeout(timer);
                resolve();
              },
              reject(error) {
                clearTimeout(timer);
                reject(error);
              },
            });
            try {
              notify({ kind: "snapshot", id: current.id, snapshot });
            } catch (error) {
              clearTimeout(timer);
              saves.delete(current.id);
              reject(error);
            }
          }),
      );
    saveQueue.set(current.id, job);
    return job;
  }
  function persist(
    current: PendingReview,
    status: StoredReviewSnapshot["status"],
  ): void {
    void saveReview(current, status).catch((error) => {
      current.sendError = errorMessage(error);
    });
  }

  let pending: PendingReview | undefined;
  let opening = 0;
  let stopped = false;
  const deferredMessages: ReviewRequest[] = [];

  function activeWorkspace(): string | undefined {
    return location.pathname.match(/^\/client\/(T[A-Z0-9]+)(?:\/|$)/)?.[1];
  }

  function inScope(): boolean {
    const workspaceId = activeWorkspace();
    return Boolean(
      workspaceId && (!selectedWorkspace || selectedWorkspace === workspaceId),
    );
  }

  function recordWorkspace(record: ComposerRecord): string | undefined {
    const workspaceId = activeWorkspace();
    const props = { ...record.parent?.props, ...record.raw };
    return inScope() && props.teamId === workspaceId ? workspaceId : undefined;
  }

  function notify(message: ReviewMessage, workspaceId?: string): void {
    const source =
      workspaceId ??
      ("id" in message
        ? pendingReviews.get(message.id)?.workspaceId
        : undefined) ??
      activeWorkspace();
    if (!source) return;
    if (!inScope() || source !== activeWorkspace()) {
      if (message.kind === "settled" || message.kind === "cancel")
        deferredMessages.push({ ...message, workspaceId: source });
      return;
    }
    window.__slackReviewBridge(
      JSON.stringify({ ...message, workspaceId: source }),
    );
  }

  function hidePanel(current: PendingReview): void {
    current.ui?.close();
    current.ui = undefined;
    if (pending === current) pending = undefined;
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
        if (pendingReviews.get(current.id) !== current) return;
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

  const injectedPanel = /* @panel@ */ null as ReviewPanelFactory | null;

  function mountPanel(current: PendingReview): ReviewPanel {
    if (!injectedPanel)
      throw new Error("Slack review panel was not installed.");
    return injectedPanel(current, {
      draftTools,
      validSuggestion,
      readableSuggestion,
      suggestionParts,
      preparePatch,
      notify: (message) => notify(message, current.workspaceId),
      beginStage,
      cancel: () => cancelReview(current),
      resolve,
      dismiss: () => {
        current.dismissed = true;
        hidePanel(current);
      },
      isSelected: (review) => pending === review,
      disableSend,
    });
  }
  async function beginStage(
    current: PendingReview,
    stage: "checking" | "review",
  ): Promise<void> {
    if (pendingReviews.get(current.id) !== current) return;
    if (!inScope() || current.workspaceId !== activeWorkspace()) {
      current.deferredReview = stage === "review";
      return;
    }
    current.deferredReview = false;
    if (stage === "review") current.initialStage = "review";
    try {
      if (!current.context && !sameDraft(current.record, current)) {
        cancelReview(current, "Draft changed before collection.");
        return;
      }
    } catch {
      cancelReview(current, "Composer unavailable before collection.");
      return;
    }
    current.phase = stage;
    current.busy = true;
    current.ui?.setStage(stage);
    const turn = current.turn;
    if (!current.context) {
      try {
        const context = await contextFor(current);
        if (pendingReviews.get(current.id) !== current || current.turn !== turn)
          return;
        if (!context) return;
        current.context = { ...context, location: current.location };
      } catch (error) {
        if (pendingReviews.get(current.id) !== current || current.turn !== turn)
          return;
        current.phase = "classification-error";
        current.busy = false;
        current.classification = { error: errorMessage(error) };
        notify({
          kind: "settled",
          id: current.id,
          state: "failed",
          error: errorMessage(error),
        });
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
    cancelReview(pending, reason);
  }

  function cancelReview(current: PendingReview, reason = "Review cancelled.") {
    notify({ kind: "cancel", id: current.id, reason }, current.workspaceId);
    current.turn++;
    current.stale = true;
    delete current.approved;
    current.busy = false;
    hidePanel(current);
    persist(current, "cancelled");
  }

  function intercept(
    record: ComposerRecord,
    args: unknown[],
  ): Promise<unknown> {
    if (!inScope()) {
      return Promise.resolve(
        Reflect.apply(record.raw.sendMessage, record.raw, args),
      );
    }
    const workspaceId = recordWorkspace(record);
    if (!workspaceId) {
      if (disableSend) {
        window.alert(
          "Sending is disabled in this development workspace. Nothing was sent.",
        );
        return Promise.resolve(null);
      }
      return Promise.resolve(
        Reflect.apply(record.raw.sendMessage, record.raw, args),
      );
    }
    const props = { ...record.parent?.props, ...record.raw };
    const conversation = props.channelDisplayName ?? props.channel?.name;
    if (conversation && ignoreConversations.includes(conversation)) {
      if (disableSend) {
        window.alert(
          "Sending is disabled in this development workspace. Nothing was sent.",
        );
        return Promise.resolve(null);
      }
      return Promise.resolve(
        Reflect.apply(record.raw.sendMessage, record.raw, args),
      );
    }

    if (stopped) {
      window.alert(
        stopped
          ? "Review is unavailable. Restart the review controller before sending."
          : "Finish or cancel the open review before sending another message.",
      );
      return Promise.resolve(null);
    }
    let fingerprint: string;
    try {
      fingerprint = snapshot(record);
    } catch (error) {
      console.error("[Slack review] Send blocked:", errorMessage(error));
      window.alert(`Nothing was sent: ${errorMessage(error)}`);
      return Promise.resolve(null);
    }
    const previous = [...pendingReviews.values()].find((item) =>
      sameDestination(record, item),
    );
    if (previous?.sending || previous?.sendUnknown)
      return Promise.resolve(null);
    if (previous && sameSnapshot(previous.approved, fingerprint))
      return sendApproved(previous, record, args);
    if (previous && sameDraft(record, previous) && !previous.stale) {
      previous.record = record;
      showPanel(previous);
      return Promise.resolve(null);
    }
    if (previous) {
      notify({
        kind: "cancel",
        id: previous.id,
        reason: "Draft changed; reviewing the current message.",
      });
      previous.turn++;
      hidePanel(previous);
      previous.indicator?.remove();
      pendingReviews.delete(previous.id);
    }
    const draft = readSnapshot(fingerprint);
    if (
      typeof draft.channel !== "string" ||
      (draft.thread !== null && typeof draft.thread !== "string")
    ) {
      window.alert(
        "The original conversation is unavailable. Nothing was sent.",
      );
      return Promise.resolve(null);
    }
    const destination: ConversationDestination = {
      workspaceId,
      channelId: draft.channel,
      threadTs: draft.thread,
    };
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
      window.alert(`Nothing was sent: ${errorMessage(error)}`);
      return Promise.resolve(null);
    }
    const id = previous?.id ?? crypto.randomUUID();
    const hasAttachments = Boolean(
      draft.hasFiles ||
      ((isRecord(draft.files) || Array.isArray(draft.files)) &&
        Object.keys(draft.files).length) ||
      ((isRecord(draft.pendingFiles) || Array.isArray(draft.pendingFiles)) &&
        Object.keys(draft.pendingFiles).length) ||
      draft.gifUnfurls,
    );
    if (
      [...pendingReviews.values()].some((item) =>
        sameSnapshot(item.fingerprint, fingerprint),
      )
    ) {
      return Promise.resolve(null);
    }
    const current: PendingReview = {
      destination,
      startedAt: Date.now(),
      workspaceId,
      id,
      record,
      args,
      fingerprint,
      original,
      reviewOriginal: draftTools.serialize(projection.text, projection.lines),
      previewOriginal: projection.text,
      elements: projection.elements,
      projection,
      location: location.href,
      turn: previous?.turn ?? 0,
      busy: false,
      applyFailed: false,
      context: undefined,
      ui: undefined,
      phase: hasAttachments ? "review" : "checking",
      initialStage: hasAttachments ? "review" : "checking",
    };
    pendingReviews.set(id, current);
    try {
      notify({
        kind: "captured",
        id,
        original: readableSuggestion(current, current.previewOriginal),
        location: current.location,
        destination: current.destination,
      });
    } catch {
      pendingReviews.delete(id);
      window.alert("The AI Tasks connection is unavailable. Nothing was sent.");
      return Promise.resolve(null);
    }
    showPanel(current);
    void saveReview(current, "queued").then(
      () => beginStage(current, current.initialStage),
      (error) => {
        current.sendError = errorMessage(error);
        current.busy = false;
      },
    );
    return Promise.resolve(null);
  }

  function scan() {
    if (stopped) {
      return;
    }
    if (!inScope()) {
      if (pending) hidePanel(pending);
      return;
    }
    for (let index = 0; index < deferredMessages.length;) {
      const message = deferredMessages[index];
      if (message?.workspaceId !== activeWorkspace()) {
        index++;
        continue;
      }
      window.__slackReviewBridge(JSON.stringify(message));
      deferredMessages.splice(index, 1);
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
      if (!recordWorkspace(record) && !disableSend) continue;
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
        if (
          pending.workspaceId === activeWorkspace() &&
          recordWorkspace(pending.record) === pending.workspaceId &&
          pending.record.element.isConnected &&
          sameDestination(pending.record, pending)
        )
          pending.ui?.refresh();
        else {
          pending.ui?.close();
          pending.ui = undefined;
          pending = undefined;
        }
      } catch {
        pending?.ui?.close();
        if (pending) pending.ui = undefined;
        pending = undefined;
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
    for (const [id, saved] of restored) {
      const record = [...records.values()].find((item) => {
        const props = { ...item.parent?.props, ...item.raw };
        return (
          props.teamId === saved.destination.workspaceId &&
          props.channelId === saved.destination.channelId &&
          (props.threadTs ?? null) === saved.destination.threadTs
        );
      });
      if (!record || pendingReviews.has(id)) continue;
      const { result, ...savedDraft } = saved;
      pendingReviews.set(id, {
        ...savedDraft,
        ...(result === undefined ? {} : { result }),
        record,
        args: [],
        elements: saved.projection.elements,
        busy: false,
        applyFailed: false,
        ui: undefined,
        context: saved.context,
        initialStage: "review",
        dismissed: true,
        stale: !["needs-approval", "ready-to-send"].includes(saved.status),
        sendUnknown: saved.status === "send-unknown",
        ...(saved.status === "send-unknown"
          ? {
              sendError:
                "Check whether this message was sent before reviewing again.",
            }
          : {}),
      });
      restored.delete(id);
    }
    for (const current of pendingReviews.values()) {
      if (current.workspaceId !== activeWorkspace()) continue;
      if (current.deferredReview) void beginStage(current, "review");
      const record = [...records.values()].find((candidate) =>
        sameDestination(candidate, current),
      );
      if (!record) {
        current.indicator?.remove();
        delete current.indicator;
        continue;
      }
      current.record = record;
      let draftError: string | undefined;
      let now: ReturnType<typeof readSnapshot> | undefined;
      try {
        now = readSnapshot(snapshot(record));
      } catch (error) {
        draftError = `Draft unavailable: ${errorMessage(error)} Your saved draft is retained.`;
      }
      const empty = now?.contents.contents.every(
        (op) => typeof op.insert === "string" && !op.insert.trim(),
      );
      if (
        !current.sending &&
        now !== undefined &&
        !empty &&
        !sameDraft(record, current) &&
        !sameSnapshot(current.approved, snapshot(record)) &&
        !current.stale
      ) {
        current.turn++;
        current.stale = true;
        delete current.approved;
        current.busy = false;
        notify({
          kind: "cancel",
          id: current.id,
          reason:
            "Draft edited. Press Slack Send to review the current message.",
        });
        notify({ kind: "settled", id: current.id, state: "stale" });
        persist(current, "stale");
        hidePanel(current);
      }
      const composer = record.element.closest(".c-wysiwyg_container");
      if (!composer) continue;
      if (!current.indicator?.isConnected) {
        const row = document.createElement("div");
        row.setAttribute("role", "status");
        row.setAttribute("aria-live", "polite");
        row.style.cssText =
          "display:flex;gap:8px;align-items:center;flex-wrap:wrap;padding:8px 12px;font-size:13px;color:inherit;border-bottom:1px solid color-mix(in srgb,currentColor 24%,transparent)";
        const label = document.createElement("span");
        label.style.cssText =
          "padding:3px 8px;border-radius:7px;font-size:12px;font-weight:600;line-height:18px;overflow-wrap:anywhere";
        const button = document.createElement("button");
        button.type = "button";
        button.textContent = "Open review";
        button.addEventListener("click", () => {
          void openReview(current.id).catch((error) => {
            current.sendError = errorMessage(error);
          });
        });
        row.append(label, button);
        composer.prepend(row);
        current.indicator = row;
      }
      const label = current.indicator.firstElementChild;
      if (label instanceof HTMLElement) {
        let light = matchMedia("(prefers-color-scheme: light)").matches;
        for (
          let surface: Element | null = composer;
          surface;
          surface = surface.parentElement
        ) {
          const channels = getComputedStyle(surface)
            .backgroundColor.match(/[\d.]+/g)
            ?.map(Number);
          if (channels && channels.length >= 3 && (channels[3] ?? 1) === 1) {
            light =
              (channels[0]! * 299 + channels[1]! * 587 + channels[2]! * 114) /
                1000 >
              150;
            break;
          }
        }
        const reviewFailed =
          !current.busy &&
          !current.sending &&
          !current.approved &&
          !current.stale &&
          (current.phase === "classification-error" ||
            (current.phase === "review" &&
              current.result !== undefined &&
              "error" in current.result));
        const tone = current.sendUnknown
          ? "attention"
          : draftError || current.sendError || reviewFailed
            ? "error"
            : current.sending || current.busy
              ? "progress"
              : "attention";
        const colors = light
          ? {
              progress: ["#204e80", "#e5effd"],
              attention: ["#705000", "#fff0cc"],
              error: ["#9a262b", "#ffe7e7"],
            }
          : {
              progress: ["#b5d6ff", "#223b55"],
              attention: ["#f5d58d", "#44371c"],
              error: ["#ffb8b5", "#492b2e"],
            };
        label.style.color = colors[tone][0] ?? "";
        label.style.backgroundColor = colors[tone][1] ?? "";
        const text =
          draftError ??
          current.sendError ??
          (current.sending
            ? "Sending to Slack"
            : current.approved
              ? "Ready to send in Slack"
              : current.stale
                ? "Needs re-review · Use Slack Send to review again"
                : current.busy
                  ? "In progress · Not sent"
                  : reviewFailed
                    ? "Review failed · Open review to retry · Not sent"
                    : "Ready to review · Not sent");
        if (label.textContent !== text) label.textContent = text;
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
    if (current.busy || current.sending) return "busy";
    const { record } = current;
    if (decision.action === "cancel") {
      cancelPending();
      return "cancelled";
    }
    if (!inScope() || recordWorkspace(record) !== current.workspaceId) {
      hidePanel(current);
      return "workspace-unavailable";
    }
    if (disableSend) {
      current.ui?.sendFailed(
        "Sending is disabled in this development workspace. Nothing was sent.",
      );
      return "send-disabled";
    }
    if (current.stale || current.sendUnknown) {
      current.ui?.sendFailed(
        "Draft changed. Close this review and press Slack Send to review the current message.",
      );
      return "stale";
    }
    if (current.applyFailed) return "apply-failed";
    try {
      if (
        !sameDraft(record, current) ||
        !["original", "revised"].includes(decision.action) ||
        typeof decision.text !== "string" ||
        (decision.action === "revised" &&
          (!validSuggestion(current, decision.text) ||
            decision.patch.text !== decision.text)) ||
        (decision.action === "original" && decision.text !== current.original)
      ) {
        current.ui?.sendFailed("The original draft changed. Nothing was sent.");
        notify({
          kind: "settled",
          id,
          state: "conflict",
          error: "The original draft changed.",
        });
        return "changed-or-invalid";
      }
    } catch {
      current.ui?.sendFailed(
        "The original composer is unavailable. Nothing was sent.",
      );
      notify({
        kind: "settled",
        id,
        state: "conflict",
        error: "The original composer is unavailable.",
      });
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
          [...new Set([...Object.keys(before), ...Object.keys(latest)])].some(
            (key) =>
              key !== "contents" &&
              key !== "url" &&
              key !== "destinations" &&
              JSON.stringify(before[key]) !== JSON.stringify(latest[key]),
          )
        ) {
          throw new Error("Slack did not preserve the expected draft.");
        }
      } catch (error) {
        current.applyFailed = applied;
        current.ui?.sendFailed(
          `${errorMessage(error)} Nothing was sent.${applied ? " The Slack draft may be partially changed. Copy the preserved Original message before cancelling." : ""}`,
        );
        return "apply-failed";
      }
    }
    current.approved = snapshot(record);
    current.dismissed = true;
    hidePanel(current);
    notify({ kind: "settled", id, state: "ready-to-send" });
    persist(current, "ready-to-send");
    return "applied";
  }

  async function sendApproved(
    current: PendingReview,
    record: ComposerRecord,
    args: unknown[],
  ): Promise<unknown> {
    if (current.sending) return null;
    if (disableSend) return null;
    const approved = current.approved;
    current.sending = true;
    delete current.approved;
    const editable = record.element.getAttribute("contenteditable");
    record.element.setAttribute("contenteditable", "false");
    try {
      await saveReview(current, "sending");
      if (
        !record.element.isConnected ||
        !sameDestination(record, current) ||
        !sameSnapshot(approved, snapshot(record))
      )
        throw new Error("Draft changed before sending. Review it again.");
      const latest = readSnapshot(snapshot(record));
      if (
        (Array.isArray(latest.pendingFiles) || isRecord(latest.pendingFiles)) &&
        Object.keys(latest.pendingFiles).length
      ) {
        throw new Error(
          "Attachments are still uploading. Wait for them and review again.",
        );
      }
      const sent = await Reflect.apply(
        record.raw.sendMessage,
        record.raw,
        args,
      );
      notify({ kind: "settled", id: current.id, state: "handed-to-slack" });
      current.indicator?.remove();
      pendingReviews.delete(current.id);
      return sent;
    } catch (error) {
      current.sendError = errorMessage(error);
      notify({
        kind: "settled",
        id: current.id,
        state: "failed",
        error: current.sendError,
      });
      return null;
    } finally {
      current.sending = false;
      if (editable === null) record.element.removeAttribute("contenteditable");
      else record.element.setAttribute("contenteditable", editable);
    }
  }

  function sameDraft(record: ComposerRecord, current: PendingReview): boolean {
    try {
      return sameSnapshot(current.fingerprint, snapshot(record));
    } catch {
      return false;
    }
  }

  function sameSnapshot(
    beforeText: string | undefined,
    afterText: string,
  ): boolean {
    if (beforeText === undefined) return false;
    try {
      const before = readSnapshot(beforeText);
      const after = readSnapshot(afterText);
      return [
        ...new Set([...Object.keys(before), ...Object.keys(after)]),
      ].every(
        (key) =>
          key === "url" ||
          key === "destinations" ||
          JSON.stringify(before[key]) === JSON.stringify(after[key]),
      );
    } catch {
      return false;
    }
  }

  function sameDestination(
    record: ComposerRecord,
    current: PendingReview,
  ): boolean {
    const props = { ...record.parent?.props, ...record.raw };
    return (
      record.element.isConnected &&
      props.teamId === current.destination.workspaceId &&
      props.channelId === current.destination.channelId &&
      (props.threadTs ?? null) === current.destination.threadTs
    );
  }

  async function openReview(id: string): Promise<void> {
    const saved = restored.get(id);
    if (saved) {
      if (saved.workspaceId !== activeWorkspace())
        throw new Error(
          "Open the original workspace before reviewing this task.",
        );
      navigate?.(saved.destination);
      const deadline = Date.now() + 5000;
      while (restored.has(id) && Date.now() < deadline && !stopped) {
        scan();
        if (restored.has(id))
          await new Promise<void>((resolve) => setTimeout(resolve, 100));
      }
    }
    scan();
    const current = pendingReviews.get(id);
    if (!current || stopped)
      throw new Error(
        "The original conversation could not be opened. Your saved draft is retained.",
      );
    if (current.sendUnknown)
      throw new Error(
        "Check whether this message was sent in Tasks before reviewing again.",
      );
    if (current.sending)
      throw new Error("Slack is processing this send request.");
    if (!inScope() || current.workspaceId !== activeWorkspace()) {
      throw new Error(
        "Open the original workspace before reviewing this task.",
      );
    }
    const attempt = ++opening;
    pending?.ui?.close();
    if (pending) pending.ui = undefined;
    pending = undefined;
    const destination = new URL(current.location);
    if (destination.origin !== location.origin) {
      throw new Error("Open the original Slack workspace before sending.");
    }
    scan();
    if (![...records.values()].some((item) => sameDestination(item, current))) {
      if (!navigate)
        throw new Error("Slack conversation navigation is unavailable.");
      navigate(current.destination);
    }
    let record: ComposerRecord | undefined;
    const deadline = Date.now() + 5000;
    while (
      !stopped &&
      attempt === opening &&
      pendingReviews.has(id) &&
      Date.now() < deadline
    ) {
      scan();
      record = [...records.values()].find((item) => sameDraft(item, current));
      if (!record) {
        const candidate = [...records.values()].find((item) =>
          sameDestination(item, current),
        );
        if (candidate) {
          const now = readSnapshot(snapshot(candidate));
          const before = readSnapshot(current.fingerprint);
          const empty = now.contents.contents.every(
            (op) => typeof op.insert === "string" && !op.insert.trim(),
          );
          const sameAttachments = [
            "files",
            "pendingFiles",
            "hasFiles",
            "gifUnfurls",
          ].every(
            (key) => JSON.stringify(now[key]) === JSON.stringify(before[key]),
          );
          if (empty && sameAttachments) {
            const input = inputFor(candidate);
            if (typeof input?.updateContents === "function") {
              input.updateContents({
                contents: [
                  {
                    delete: now.contents.contents.reduce(
                      (length, op) =>
                        length +
                        (typeof op.insert === "string" ? op.insert.length : 1),
                      0,
                    ),
                  },
                  ...before.contents.contents,
                ],
              });
              if (sameDraft(candidate, current)) record = candidate;
            }
          }
        }
      }
      if (record) break;
      await new Promise<void>((resolve) => setTimeout(resolve, 100));
    }
    if (attempt !== opening || stopped || !pendingReviews.has(id)) return;
    if (!record) {
      if (
        ![...records.values()].some((item) => sameDestination(item, current))
      ) {
        throw new Error(
          "The original conversation could not be opened. Retry this task. Nothing was sent.",
        );
      }
      const error =
        "This conversation has a different draft or missing attachments. Keep your draft and press Slack Send to review its current contents. Nothing was sent.";
      notify({ kind: "settled", id, state: "conflict", error });
      const candidate = [...records.values()].find((item) =>
        sameDestination(item, current),
      );
      if (!candidate) throw new Error(error);
      notify({
        kind: "cancel",
        id,
        reason: "Draft conflict. Review the current draft before sending.",
      });
      current.turn++;
      current.stale = true;
      current.busy = false;
      delete current.approved;
      persist(current, "conflict");
      current.record = candidate;
      const projection = draftTools.capture(
        readSnapshot(snapshot(candidate)).contents.contents,
      );
      const text = projection.text.replace(
        /⟦SLACK_ELEMENT_[^⟧]*⟧/g,
        (token) =>
          projection.elements.find((element) => element.token === token)
            ?.label ?? "[Unknown element]",
      );
      window.__slackAiTasks?.close();
      hidePanel(current);
      showPanel(current);
      current.ui?.conflict(text, () => {
        cancelReview(
          current,
          "Current draft selected. Press Slack Send to review it.",
        );
        current.record.element.focus();
      });
      return;
    }
    current.record = record;
    current.fingerprint = snapshot(record);
    current.dismissed = false;
    window.__slackAiTasks?.close();
    showPanel(current);
  }

  function showPanel(current: PendingReview): void {
    if (current.sending || window.__slackAiTasks?.isOpen()) return;
    if (
      !inScope() ||
      current.workspaceId !== activeWorkspace() ||
      !current.record.element.isConnected ||
      !sameDestination(current.record, current)
    )
      return;
    if (pending && pending !== current) hidePanel(pending);
    if (current.ui) return;
    pending = current;
    const phase = current.phase;
    current.ui = mountPanel(current);
    if (phase === "confirm") current.ui.confirm();
    else if (phase === "classification-error") {
      current.ui.classificationFailed(
        current.classification && "error" in current.classification
          ? current.classification.error
          : "Context collection failed. Retry the review.",
      );
    } else {
      current.ui.setStage(
        phase === "loading"
          ? "loading"
          : phase === "checking"
            ? "checking"
            : "review",
      );
      if (current.result) current.ui.receive(current.result);
    }
    if (current.sendError) current.ui.sendFailed(current.sendError);
  }

  window.__slackMessageReview = {
    owner,
    receiveSnapshots(snapshots) {
      for (const saved of snapshots) {
        const current = pendingReviews.get(saved.id);
        if (["handed-to-slack", "completed"].includes(saved.status)) {
          current?.indicator?.remove();
          if (current) hidePanel(current);
          pendingReviews.delete(saved.id);
          restored.delete(saved.id);
          continue;
        }
        if (current?.sendUnknown && saved.status !== "send-unknown") {
          current.sendUnknown = false;
          delete current.sendError;
          current.stale = true;
        }
        if (!current) restored.set(saved.id, saved);
      }
      scan();
    },
    receiveSaved(id, turn, error) {
      const pendingSave = saves.get(id);
      if (!pendingSave || pendingSave.turn !== turn) return;
      saves.delete(id);
      if (error) pendingSave.reject(new Error(error));
      else pendingSave.resolve();
    },
    open: openReview,
    close() {
      opening++;
      if (!pending) return;
      pending.dismissed = true;
      hidePanel(pending);
    },
    has(id) {
      return pendingReviews.has(id);
    },
    activity(id, tools) {
      const current = pendingReviews.get(id);
      if (!current) return;
      current.tools = tools;
      if (inScope() && current.workspaceId === activeWorkspace())
        current.ui?.refresh();
    },
    cancel(id) {
      const current = pendingReviews.get(id);
      if (current) cancelReview(current);
    },
    pulse(id) {
      if (id !== owner) return false;
      lastPulse = Date.now();
      return true;
    },
    receive(id, turn, result) {
      const current = pendingReviews.get(id);
      if (!current || current.turn !== turn || current.phase !== "review")
        return;
      current.result = result;
      current.busy = false;
      current.ui?.receive(result);
      persist(current, "error" in result ? "failed" : "needs-approval");
    },
    receiveClassification(id, turn, result) {
      const current = pendingReviews.get(id);
      if (!current || current.turn !== turn || current.phase !== "checking")
        return;
      current.classification = result;
      current.busy = false;
      if ("error" in result) {
        current.phase = "classification-error";
        current.ui?.classificationFailed(result.error);
      } else if (
        result.choice === "simple_reply" ||
        result.choice === "link_share"
      ) {
        current.phase = "confirm";
        current.ui?.confirm();
        persist(current, "needs-approval");
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
      for (const current of pendingReviews.values()) {
        hidePanel(current);
        current.indicator?.remove();
      }
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
