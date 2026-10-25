(() => {
  if (window !== window.top || location.origin !== "https://app.slack.com") {
    return;
  }
  if (window.__slackMessageReview) {
    throw new Error(
      "Slack review hook is already installed. Stop its controller first.",
    );
  }
  const owner = "@controllerId@";
  const draftTools = /* @draft@ */ null;
  let lastPulse = Date.now();
  const records = new Map();
  let pending;
  let stopped = false;

  function notify(message) {
    window.__slackReviewBridge(JSON.stringify(message));
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
    for (; fiber; fiber = fiber.return) {
      result.push(fiber);
    }
    return result;
  }

  function threadSource(record, props) {
    const candidates = ancestors(record.element);
    for (const panel of document.querySelectorAll(
      '[data-qa="threads_flexpane"], .p-threads_flexpane_container',
    ))
      candidates.push(...ancestors(panel));
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
      "This thread view is not supported. Cancel and open the thread in the side panel.",
    );
  }

  function threadMessages(thread, props, fetched) {
    const root = thread.rootMsg;
    if (root?.ts !== props.threadTs) return;
    const messages =
      fetched ?? thread.timestamps.map((ts) => thread.messages?.[ts]);
    const replies = [
      ...new Map(
        messages
          .filter(
            (message) =>
              message?.thread_ts === props.threadTs &&
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
      !Number.isInteger(count) ||
      replies.length !== Math.min(9, count) ||
      (count > 0 && replies.at(-1)?.ts !== root.latest_reply)
    )
      return;
    return [root, ...replies];
  }

  async function contextFor(current) {
    const record = current.record;
    const props = { ...record.parent?.props, ...record.raw };
    const context = {
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
    let thread = threadSource(record, props);
    let messages = threadMessages(thread, props);
    if (!messages) {
      if (typeof thread.load !== "function") {
        throw new Error(
          "History loading is not supported in this thread view.",
        );
      }
      current.ui.setStage("loading");
      let timeout;
      try {
        const result = await Promise.race([
          thread.load({
            channelId: props.channelId,
            threadTs: props.threadTs,
            latest: thread.rootMsg?.latest_reply,
            limit: 10,
            skipSubscriptionUpdate: true,
          }),
          new Promise((_, reject) => {
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
        messages = threadMessages(thread, props, result?.msgs ?? []);
      } catch (error) {
        throw new Error(`Could not load thread history: ${error.message}`);
      } finally {
        clearTimeout(timeout);
      }
      if (!messages)
        throw new Error(
          "The latest thread history is still incomplete. Retry or send the original.",
        );
    }
    const memberProps = ancestors(record.element)
      .map((fiber) => fiber.stateNode?.props ?? fiber.memoizedProps)
      .find((candidate) => typeof candidate?.getMember === "function");
    context.threadHistory = messages.map((message, index) => {
      if (
        !message ||
        typeof message.text !== "string" ||
        (index && message.thread_ts !== props.threadTs)
      )
        throw new Error(
          "Thread message text is unavailable. Retry or send the original.",
        );
      const member = memberProps?.getMember(message.user);
      const author =
        member?.profile?.display_name ||
        member?.profile?.real_name ||
        member?.real_name ||
        member?.name ||
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

  function snapshot(record) {
    const input = record.instance.getInputRef();
    if (!record.element.isConnected || !input) {
      throw new Error("The composer is no longer available.");
    }
    const contents = input.getContents();
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

  function suggestionParts(text) {
    return draftTools.parts(text);
  }

  function validSuggestion(current, text) {
    return draftTools.valid(current.elements, text);
  }

  function readableSuggestion(current, text) {
    return text.replace(
      /⟦SLACK_ELEMENT_[^⟧]*⟧/g,
      (token) =>
        current.elements.find((element) => element.token === token)?.label ??
        "[Unknown element]",
    );
  }

  function mountPanel(current) {
    const editor = current.record.element;
    const composer =
      editor.closest(".c-wysiwyg_container") ?? editor.parentElement;
    const host = document.createElement("div");
    host.style.cssText = "position:fixed;z-index:2147483647;display:block";
    const root = host.attachShadow({ mode: "open" });
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
      .assessment { margin-bottom:12px; }
      .assessment p { margin:4px 0 10px; white-space:pre-wrap; overflow-wrap:anywhere; }
    `;
    root.append(style);
    function node(tag, text, parent, className) {
      const element = document.createElement(tag);
      if (text) element.textContent = text;
      if (className) element.className = className;
      parent.append(element);
      return element;
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
    const coreQuestion = node("p", "", assessmentPanel);
    node("label", "Draft assessment", assessmentPanel);
    const assessment = node("p", "", assessmentPanel);
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
    let suggestionError;
    let hasSuggestion = false;
    let reviewedSuggestion;
    let suggestionWidth = 0;
    let lastValidText = current.previewOriginal;
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

    const chips = new WeakMap();
    function suggestionText() {
      if (!current.elements.length) return suggestion.value;
      function read(element) {
        if (element.nodeType === Node.TEXT_NODE) return element.textContent;
        if (chips.has(element)) return chips.get(element);
        if (element.nodeName === "BR") return "\n";
        const text = [...element.childNodes].map(read).join("");
        return ["DIV", "P"].includes(element.nodeName) && element !== suggestion
          ? `${text}\n`
          : text;
      }
      return read(suggestion);
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
      const valid =
        !suggestionError && validSuggestion(current, suggestionText());
      revised.disabled =
        current.busy || current.applyFailed || !hasSuggestion || !valid;
      staleAssessment.hidden =
        assessmentPanel.hidden || suggestionText() === reviewedSuggestion;
      note.textContent =
        suggestionError ||
        (!valid ? "Keep protected elements in their original order." : "");
      note.hidden = !note.textContent;
      resizeSuggestion();
    }
    function setSuggestion(text) {
      suggestionError = validSuggestion(current, text)
        ? undefined
        : "The suggestion changed protected elements or is empty. Retry the review.";
      if (!current.elements.length) {
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
      updateSuggestionState();
    }
    function insertText(text) {
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
      lastValidText = suggestionText();
      suggestionError = undefined;
      updateSuggestionState();
    }
    if (current.elements.length) {
      suggestion.addEventListener("beforeinput", (event) => {
        for (const target of event.getTargetRanges?.() ?? []) {
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
        event.preventDefault();
        if (!current.busy && hasSuggestion)
          insertText(event.clipboardData.getData("text/plain"));
      });
      suggestion.addEventListener("drop", (event) => event.preventDefault());
    }
    setSuggestion(current.previewOriginal);

    function setBusy(busy) {
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
      suggestion.readOnly = busy || !hasSuggestion;
      if (current.elements.length)
        suggestion.contentEditable = busy || !hasSuggestion ? "false" : "true";
    }
    function setStage(stage) {
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
    function classificationFailed(error) {
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
          suggestion: suggestionText(),
        });
      } catch {
        current.ui.receive({
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
      if (event.key === "Escape") cancelPending();
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
      lastValidText = suggestionText();
      suggestionError = undefined;
      updateSuggestionState();
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
    revised.onclick = () =>
      resolve(current.id, { action: "revised", text: suggestionText() });

    // Keep the review outside React's tree while anchoring it to the active composer.
    const saved = new Map();
    function lock(element, attribute, value) {
      if (!saved.has(element)) saved.set(element, new Map());
      const attributes = saved.get(element);
      if (!attributes.has(attribute))
        attributes.set(attribute, element.getAttribute(attribute));
      if (element.getAttribute(attribute) !== value)
        element.setAttribute(attribute, value);
    }
    function refresh() {
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
    function guard(event) {
      if (!composer.contains(event.target)) return;
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
          original.disabled = true;
          revised.disabled = true;
          ask.disabled = true;
          retry.hidden = true;
          check.disabled = true;
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
        if (result.error) {
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
          coreQuestion.textContent = readableSuggestion(
            current,
            result.coreQuestion ?? "",
          );
          assessment.textContent = readableSuggestion(
            current,
            result.assessment ?? "",
          );
          setSuggestion(result.suggestion);
          lastValidText = result.suggestion;
          reviewedSuggestion = suggestionText();
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

  async function beginStage(current, stage) {
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
    current.ui.setStage(stage);
    const turn = current.turn;
    if (!current.context) {
      try {
        const context = await contextFor(current);
        if (pending !== current || current.turn !== turn) return;
        if (snapshot(current.record) !== current.fingerprint) {
          cancelPending("Draft changed.");
          return;
        }
        current.context = context;
      } catch (error) {
        if (pending !== current || current.turn !== turn) return;
        current.ui.setStage("checking");
        current.ui.classificationFailed(error.message);
        return;
      }
    }
    current.ui.setStage(stage);
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
      if (stage === "checking") current.ui.classificationFailed(error);
      else current.ui.receive({ error });
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

  function intercept(record, args) {
    if (stopped || pending) {
      return Promise.resolve(null);
    }
    let fingerprint;
    try {
      fingerprint = snapshot(record);
    } catch (error) {
      console.error("[Slack review] Send blocked:", error.message);
      return Promise.resolve(null);
    }
    const draft = JSON.parse(fingerprint);
    const original = draft.contents.contents
      .map((op) =>
        typeof op.insert === "string" ? op.insert : JSON.stringify(op.insert),
      )
      .join("")
      .replace(/\n$/, "");
    let projection;
    try {
      projection = draftTools.capture(draft.contents.contents);
    } catch (error) {
      console.error("[Slack review] Draft capture failed:", error.message);
      return Promise.resolve(null);
    }
    const id = crypto.randomUUID();
    const hasAttachments = Boolean(
      draft.hasFiles ||
      Object.keys(draft.files ?? {}).length ||
      Object.keys(draft.pendingFiles ?? {}).length ||
      draft.gifUnfurls,
    );
    return new Promise((finish) => {
      pending = {
        id,
        record,
        args,
        fingerprint,
        original,
        reviewOriginal: projection.text,
        previewOriginal: projection.text,
        elements: projection.elements,
        projection,
        finish,
        turn: 0,
        phase: hasAttachments ? "review" : "checking",
        initialStage: hasAttachments ? "review" : "checking",
      };
      try {
        pending.ui = mountPanel(pending);
        beginStage(pending, pending.phase);
      } catch {
        cancelPending();
      }
    });
  }

  function scan() {
    if (stopped) {
      return;
    }
    for (const element of document.querySelectorAll(
      '.ql-editor[contenteditable="true"]',
    )) {
      let instance;
      let parent;
      for (const fiber of ancestors(element)) {
        if (fiber.stateNode?.constructor?.displayName === "MessageInput") {
          instance = fiber.stateNode;
        }
        if (
          ["MessagePaneInput", "InputContainer"].includes(
            fiber.stateNode?.constructor?.displayName,
          )
        ) {
          parent = fiber.stateNode;
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
      const record = {
        instance,
        parent,
        element,
        descriptor,
        raw: instance.props,
        proxy: undefined,
      };
      const wrappedSend = (...args) => intercept(record, args);
      function updateProps(props) {
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
        enumerable: descriptor.enumerable,
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
          const before = JSON.parse(pending.fingerprint);
          const after = JSON.parse(latest);
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

  function resolve(id, decision) {
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
          !validSuggestion(current, decision.text)) ||
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
        const input = record.instance.getInputRef();
        if (typeof input?.updateContents !== "function") {
          throw new Error(
            "This Slack editor does not support formatted updates.",
          );
        }
        const patch = draftTools.patch(
          current.projection,
          decision.text,
          (html) => {
            const quill = input.instance?.quill ?? input.quill;
            if (
              typeof input.convertSlackHTMLToDelta !== "function" ||
              typeof quill?.getFormat !== "function"
            ) {
              throw new Error(
                "This Slack editor does not support list conversion.",
              );
            }
            const descriptor = Object.getOwnPropertyDescriptor(
              quill,
              "getFormat",
            );
            // Neutralize cursor formatting only during the synchronous clipboard conversion.
            Object.defineProperty(quill, "getFormat", {
              configurable: true,
              value: () => ({}),
            });
            try {
              return input.convertSlackHTMLToDelta(html);
            } finally {
              if (descriptor)
                Object.defineProperty(quill, "getFormat", descriptor);
              else delete quill.getFormat;
            }
          },
        );
        applied = true;
        input.updateContents({ contents: patch.contents });
        const latest = JSON.parse(snapshot(record));
        const before = JSON.parse(current.fingerprint);
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
        current.ui.sendFailed(
          `${error.message} Nothing was sent.${applied ? " Cancel and inspect the draft in Slack." : ""}`,
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
        error.message,
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
      pending.ui.receive(result);
    },
    receiveClassification(id, turn, result) {
      if (
        pending?.id !== id ||
        pending.turn !== turn ||
        pending.phase !== "checking"
      )
        return;
      const current = pending;
      if (result.error) {
        current.ui.classificationFailed(result.error);
      } else if (["simple_reply", "link_share"].includes(result.choice)) {
        current.ui.confirm();
      } else if (result.choice === "review") {
        beginStage(current, "review");
      } else {
        current.ui.classificationFailed(
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
