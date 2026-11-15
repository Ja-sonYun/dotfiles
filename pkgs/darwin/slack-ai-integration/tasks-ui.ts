(() => {
  const navigate = /* @navigation@ */ null as
    typeof navigateToConversation | null;
  let navigationAttempt = 0;
  const owner = "@controllerId@";
  const workspaceRestriction: string | null = /* @workspaceId@ */ null;
  if (window.__slackAiTasks) return;

  let lastPulse = Date.now();
  let tasks: TaskView[] = [];
  let selected: string | undefined;
  let filter = "all";
  let opened = false;
  let stopped = false;
  let workspaceId: string | undefined;
  let previousFocus: HTMLElement | undefined;

  function activeWorkspace(): string | undefined {
    return location.pathname.match(/^\/client\/(T[A-Z0-9]+)(?:\/|$)/)?.[1];
  }

  function inWorkspace(): boolean {
    const active = activeWorkspace();
    return Boolean(
      active && (!workspaceRestriction || active === workspaceRestriction),
    );
  }
  const terminal = new Set([
    "completed",
    "handed-to-slack",
    "failed",
    "cancelled",
    "interrupted",
  ]);
  const labels: Record<string, string> = {
    queued: "Queued",
    running: "In progress",
    "needs-approval": "Ready to review",
    stale: "Needs re-review",
    "ready-to-send": "Ready to send in Slack",
    sending: "Sending to Slack",
    "send-unknown": "Check whether sent",
    completed: "Complete",
    "handed-to-slack": "Handed to Slack",
    failed: "Failed",
    cancelled: "Cancelled",
    interrupted: "Interrupted",
    conflict: "Draft conflict",
  };

  const attention = new Set([
    "needs-approval",
    "stale",
    "ready-to-send",
    "send-unknown",
    "conflict",
    "failed",
    "interrupted",
  ]);

  function statusBadge(task: TaskView): HTMLSpanElement {
    const state = task.status;
    const tone = ["running", "sending"].includes(state)
      ? "progress"
      : ["failed", "conflict"].includes(state)
        ? "error"
        : attention.has(state)
          ? "attention"
          : state === "completed"
            ? "success"
            : "neutral";
    const badge = element("span", "", `status status-${tone}`);
    const icon = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    icon.setAttribute("viewBox", "0 0 24 24");
    icon.setAttribute("aria-hidden", "true");
    const path = document.createElementNS("http://www.w3.org/2000/svg", "path");
    const paths: Record<string, string> = {
      progress: "M12 8v4l3 3M22 12a10 10 0 1 1-10-10 10 10 0 0 1 10 10Z",
      attention: "M12 8v4M12 16h.01M22 12a10 10 0 1 1-10-10 10 10 0 0 1 10 10Z",
      error: "m15 9-6 6m0-6 6 6M22 12a10 10 0 1 1-10-10 10 10 0 0 1 10 10Z",
      success: "m9 12 2 2 4-4M22 12a10 10 0 1 1-10-10 10 10 0 0 1 10 10Z",
      neutral: "M8 12h8M22 12a10 10 0 1 1-10-10 10 10 0 0 1 10 10Z",
    };
    path.setAttribute("d", paths[tone] ?? "");
    icon.append(path);
    badge.append(icon, element("span", labels[state] ?? state));
    return badge;
  }

  function element<K extends keyof HTMLElementTagNameMap>(
    tag: K,
    text = "",
    className = "",
  ): HTMLElementTagNameMap[K] {
    const node = document.createElement(tag);
    node.textContent = text;
    node.className = className;
    return node;
  }

  function button(
    text: string,
    action: () => void,
    className = "",
  ): HTMLButtonElement {
    const node = element("button", text, className);
    node.type = "button";
    node.addEventListener("click", action);
    return node;
  }

  function notify(
    payload:
      | { kind: "list" }
      | { kind: "cancel"; id: string }
      | { kind: "resolve-send"; id: string; sent: boolean },
  ): void {
    const active = activeWorkspace();
    if (!active || !inWorkspace()) return;
    try {
      window.__slackAiTasksBridge(
        JSON.stringify({ ...payload, workspaceId: active }),
      );
    } catch {
      notice.textContent =
        "The AI connection is unavailable. No message was sent.";
    }
  }

  const host = element("div");
  host.dataset.slackAiTasksPanel = owner;
  host.style.cssText =
    "position:fixed;top:40px;right:0;bottom:0;left:70px;z-index:1000;display:none";
  const root = host.attachShadow({ mode: "open" });
  const style = element("style");
  style.textContent = `
    :host{--bg:#1a1d21;--surface:#222529;--raised:#292d32;--line:#383d42;--text:#d6d8db;--muted:#a6adb3;--accent:#b7c9e2;--soft:#293a50;--link:#92bdd4;--progress-text:#b5d6ff;--progress-bg:#223b55;--attention-text:#f5d58d;--attention-bg:#44371c;--error-text:#ffb8b5;--error-bg:#492b2e;--success-text:#a9dfba;--success-bg:#243e2d;--neutral-text:#c8cdd3;--neutral-bg:#30353b;--radius:7px;color-scheme:dark;font:14px/1.5 system-ui;color:var(--text)}
    :host([data-theme=light]){--bg:#ffffff;--surface:#f6f7f9;--raised:#eef0f3;--line:#c9ced6;--text:#20252c;--muted:#555e69;--accent:#234d7c;--soft:#e4edf8;--link:#185a91;--progress-text:#204e80;--progress-bg:#e5effd;--attention-text:#705000;--attention-bg:#fff0cc;--error-text:#9a262b;--error-bg:#ffe7e7;--success-text:#24623b;--success-bg:#e4f3e9;--neutral-text:#48515d;--neutral-bg:#eceff3;color-scheme:light}
    *{box-sizing:border-box}button,input{font:inherit}button,a{touch-action:manipulation}
    button{cursor:pointer;color:inherit;background:var(--raised);border:1px solid var(--line);border-radius:var(--radius);padding:7px 12px}
    button:hover{background:var(--surface)}button:active{background:var(--soft)}button:disabled{opacity:.5;cursor:default}
    button:focus-visible,input:focus-visible,a:focus-visible,summary:focus-visible{outline:2px solid var(--accent);outline-offset:2px}
    a{color:var(--link)}h1,h2,h3,p{margin:0}h1{font-size:23px}h2{font-size:23px}h3{font-size:14px}
    .shell{height:100%;display:flex;flex-direction:column;background:var(--bg);border:1px solid var(--line)}
    header{display:flex;align-items:center;justify-content:space-between;gap:16px;padding:20px 30px 10px}
    nav{display:flex;gap:12px;flex-wrap:wrap;padding:0 30px;border-bottom:1px solid var(--line)}
    nav button{background:transparent;border:0;border-bottom:2px solid transparent;border-radius:0;padding:14px 0;margin-right:14px;color:var(--muted)}
    nav button[aria-pressed=true]{border-bottom-color:var(--accent);color:var(--text)}
    input{min-width:120px;max-width:240px;margin:8px 0 8px auto;background:var(--surface);color:inherit;border:1px solid var(--line);border-radius:var(--radius);padding:7px 10px}
    .content{display:grid;grid-template-columns:minmax(240px,32%) minmax(0,1fr);min-height:0;flex:1}
    .list{overflow:auto;border-right:1px solid var(--line);padding:18px}
    .row{position:relative;display:block;text-align:left;width:100%;margin-bottom:4px;padding:14px;background:transparent;border-color:transparent}
    .row[aria-current=true]{background:var(--surface);border-color:var(--line)}.row strong{display:block;margin:5px 0}
    .row-time{display:block;color:var(--muted);font-size:12px;margin-top:6px}
    .inbox{display:block}.inbox .detail{display:none}.inbox .list{height:100%;border:0;padding:24px 30px}
    .inbox .row{padding:18px 220px 18px 16px;border-bottom:1px solid var(--line);border-radius:0}
    .inbox .row .status{position:absolute;right:16px;top:21px}.inbox .row-time{position:absolute;right:16px;bottom:20px}
    .inbox-intro{padding:16px 18px;background:var(--surface);border:1px solid var(--line);border-radius:var(--radius);margin-bottom:24px}
    .group-heading{margin:22px 0 10px;font-size:13px;color:var(--muted)}.back{margin-bottom:16px}
    .detail{overflow:auto;padding:28px;display:flex;flex-direction:column;gap:20px}
    .muted{color:var(--muted);font-size:12px}.status{display:inline-flex;align-items:center;align-self:flex-start;gap:6px;max-width:100%;padding:3px 8px;border-radius:var(--radius);font-size:12px;font-weight:600;line-height:18px;overflow-wrap:anywhere}
    .status svg{width:14px;height:14px;flex:none;fill:none;stroke:currentColor;stroke-width:1.8;stroke-linecap:round;stroke-linejoin:round}
    .status-progress{color:var(--progress-text);background:var(--progress-bg)}.status-attention{color:var(--attention-text);background:var(--attention-bg)}.status-error{color:var(--error-text);background:var(--error-bg)}.status-success{color:var(--success-text);background:var(--success-bg)}.status-neutral{color:var(--neutral-text);background:var(--neutral-bg)}
    .sr-only{position:absolute;width:1px;height:1px;padding:0;margin:-1px;overflow:hidden;clip-path:inset(50%);white-space:nowrap}
    .section{border:1px solid var(--line);border-radius:var(--radius);padding:18px;display:flex;flex-direction:column;gap:10px;background:var(--surface)}
    .comparison{display:grid;grid-template-columns:1fr 1fr;gap:16px}
    .text{white-space:pre-wrap;overflow-wrap:anywhere}.actions{display:flex;gap:8px;flex-wrap:wrap}
    .primary{background:var(--accent);color:var(--bg);border-color:var(--accent)}.primary:hover{background:var(--text)}
    .notice{padding:0 24px;color:var(--attention-text);background:var(--attention-bg)}.notice:not(:empty){padding:10px 24px;border-bottom:1px solid var(--line)}
    details{border-bottom:1px solid var(--line);padding:10px 0}summary{cursor:pointer;overflow-wrap:anywhere}
    footer{padding:10px 24px;border-top:1px solid var(--line);color:var(--muted);font-size:12px}
    @media(max-width:760px){.content{grid-template-columns:1fr}.list{max-height:32vh;border-bottom:1px solid var(--line)}.inbox .list{max-height:none}.detail{padding:18px}.comparison{grid-template-columns:1fr}nav,header{padding:12px}.inbox .row{padding-right:16px}.inbox .row .status,.inbox .row-time{position:static}}
  `;
  const shell = element("section", "", "shell");
  shell.setAttribute("aria-label", "Tasks");
  shell.tabIndex = -1;
  const header = element("header");
  header.append(
    element("h1", "Tasks"),
    button("Close", () => show(false)),
  );
  const nav = element("nav");
  nav.setAttribute("aria-label", "Task filters");
  const filterButtons = new Map<string, HTMLButtonElement>();
  for (const [value, label] of [
    ["all", "All tasks"],
    ["approval", "Needs you"],
    ["progress", "In progress"],
    ["complete", "Completed"],
  ]) {
    if (!value || !label) continue;
    const control = button(label, () => {
      filter = value;
      render();
    });
    filterButtons.set(value, control);
    nav.append(control);
  }
  const search = element("input");
  search.type = "search";
  search.placeholder = "Search tasks";
  search.setAttribute("aria-label", "Search tasks");
  search.addEventListener("input", render);
  nav.append(search);
  const notice = element("p", "", "notice");
  notice.setAttribute("role", "status");
  const statusAnnouncement = element("p", "", "sr-only");
  statusAnnouncement.setAttribute("role", "status");
  statusAnnouncement.setAttribute("aria-atomic", "true");
  const content = element("div", "", "content");
  const list = element("div", "", "list");
  list.setAttribute("aria-label", "Tasks");
  const detail = element("article", "", "detail");
  content.append(list, detail);
  shell.append(
    header,
    nav,
    notice,
    statusAnnouncement,
    content,
    element(
      "footer",
      "Choose a version in the conversation, then use Slack’s Send button or Enter to send it.",
    ),
  );
  root.append(style, shell);
  document.body.append(host);

  const railHost = element("div");
  railHost.dataset.slackAiTasks = owner;
  const railRoot = railHost.attachShadow({ mode: "open" });
  const railStyle = element("style");
  railStyle.textContent = `
    :host{display:block;color:inherit;font:inherit}
    button{position:relative;display:grid;justify-items:center;gap:3px;width:100%;min-height:54px;padding:3px 0;border:0;border-radius:8px;background:transparent;color:inherit;font:inherit;cursor:pointer}
    button:hover{background:#ffffff0a}button[aria-pressed=true] .icon{background:#385864;color:#f3f6f7}
    button:focus-visible{outline:2px solid #93c5a4;outline-offset:2px}
    .icon{display:grid;place-items:center;width:34px;height:34px;border-radius:8px}
    svg{width:20px;height:20px;fill:none;stroke:currentColor;stroke-width:1.7;stroke-linecap:round;stroke-linejoin:round}
    .label{font-size:10px;line-height:14px;white-space:nowrap}.badge{position:absolute;top:0;right:3px;min-width:16px;padding:0 4px;border-radius:8px;background:#dce9d3;color:#23331c;font:600 10px/16px system-ui}
    [hidden]{display:none!important}
  `;
  const railButton = button("", () => {
    selected = undefined;
    show(!opened);
  });
  railButton.setAttribute("aria-label", "Tasks");
  railButton.setAttribute("aria-pressed", "false");
  railButton.setAttribute("aria-expanded", "false");
  const railIcon = element("span", "", "icon");
  const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  svg.setAttribute("viewBox", "0 0 24 24");
  svg.setAttribute("aria-hidden", "true");
  const path = document.createElementNS("http://www.w3.org/2000/svg", "path");
  path.setAttribute(
    "d",
    "M9 6h11M9 12h11M9 18h11M3 6l1 1 2-2M3 12l1 1 2-2M3 18l1 1 2-2",
  );
  svg.append(path);
  railIcon.append(svg);
  const badge = element("span", "", "badge");
  badge.hidden = true;
  railButton.append(railIcon, element("span", "Tasks", "label"), badge);
  railRoot.append(railStyle, railButton);

  function positionPanel(): void {
    const main = document.querySelector<HTMLElement>(
      '[data-qa="primary_view"], .p-client_workspace__primary_view, .p-workspace__primary_view',
    );
    const rect = main?.getBoundingClientRect();
    const rail = railHost.getBoundingClientRect();
    const left =
      rect && rect.width > 300 ? rect.left : Math.max(rail.right, 64);
    const top = rect && rect.height > 200 ? rect.top : 40;
    if (host.style.left !== `${left}px`) host.style.left = `${left}px`;
    if (host.style.top !== `${top}px`) host.style.top = `${top}px`;
  }

  function syncWorkspace(): void {
    let surface =
      document.querySelector<HTMLElement>(
        '[data-qa="primary_view"], .p-client_workspace__primary_view, .p-workspace__primary_view',
      ) ?? document.body;
    let light = matchMedia("(prefers-color-scheme: light)").matches;
    while (surface) {
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
      if (!surface.parentElement) break;
      surface = surface.parentElement;
    }
    const theme = light ? "light" : "dark";
    if (host.dataset.theme !== theme) host.dataset.theme = theme;
    const active = activeWorkspace();
    if (active !== workspaceId) {
      workspaceId = active;
      selected = undefined;
      tasks = [];
      show(false);
      render();
      if (inWorkspace()) notify({ kind: "list" });
    }
    if (!inWorkspace()) {
      railHost.remove();
      host.style.display = "none";
      return;
    }
    if (!railHost.isConnected) {
      const activity = [
        ...document.querySelectorAll<HTMLElement>('button, a, [role="tab"]'),
      ].find((node) => {
        const name = `${node.getAttribute("aria-label") ?? ""} ${node.getAttribute("data-qa") ?? ""} ${node.textContent ?? ""}`;
        const rect = node.getBoundingClientRect();
        return (
          /activity|アクティビティ|활동/i.test(name) &&
          rect.left < 100 &&
          rect.width > 20 &&
          rect.width < 110 &&
          rect.height > 20
        );
      });
      if (activity) {
        const container = activity.parentElement;
        const anchor =
          container &&
          container.getBoundingClientRect().height < 90 &&
          container.getBoundingClientRect().width < 110
            ? container
            : activity;
        const rect = anchor.getBoundingClientRect();
        railHost.style.width = `${rect.width}px`;
        railHost.style.color = getComputedStyle(activity).color;
        anchor.after(railHost);
      }
    }
    if (opened) positionPanel();
  }

  let scanScheduled = false;
  const scheduleScan = () => {
    if (scanScheduled || stopped) return;
    scanScheduled = true;
    requestAnimationFrame(() => {
      scanScheduled = false;
      if (!stopped) syncWorkspace();
    });
  };
  const observer = new MutationObserver(scheduleScan);
  observer.observe(document.body, { childList: true, subtree: true });
  window.addEventListener("popstate", scheduleScan);
  window.addEventListener("resize", scheduleScan);
  const onOutsideNavigation = (event: MouseEvent) => {
    if (!opened || event.composedPath().includes(railHost)) return;
    const target = event.target;
    if (!(target instanceof Element)) return;
    const control = target.closest<HTMLElement>('a,button,[role="tab"]');
    if (
      control &&
      control.getBoundingClientRect().left <
        railHost.getBoundingClientRect().right
    )
      show(false);
  };
  document.addEventListener("click", onOutsideNavigation, true);

  function show(value: boolean): void {
    if (value && !inWorkspace()) return;
    if (value && !opened)
      previousFocus =
        document.activeElement instanceof HTMLElement
          ? document.activeElement
          : undefined;
    opened = value;
    host.style.display = value ? "block" : "none";
    railButton.setAttribute("aria-pressed", String(value));
    railButton.setAttribute("aria-expanded", String(value));
    if (value) {
      window.__slackMessageReview?.close();
      positionPanel();
      notify({ kind: "list" });
      render();
      search.focus();
    } else if (previousFocus?.isConnected) {
      previousFocus.focus();
    }
  }

  function section(title: string, text: string): void {
    const block = element("section", "", "section");
    block.append(element("h3", title), element("p", text, "text"));
    detail.append(block);
  }

  function safeLink(url: string): string | undefined {
    try {
      const parsed = new URL(url);
      return parsed.protocol === "https:" &&
        (parsed.hostname === "app.slack.com" ||
          parsed.hostname.endsWith(".slack.com"))
        ? parsed.href
        : undefined;
    } catch {
      return undefined;
    }
  }

  function conversationLink(
    text: string,
    href: string,
    destination?: ConversationDestination,
  ): HTMLAnchorElement {
    const link = element("a", text);
    link.href = href;
    if (!destination) return link;
    link.addEventListener("click", (event) => {
      if (event.ctrlKey || event.metaKey || event.shiftKey || event.altKey)
        return;
      event.preventDefault();
      navigationAttempt++;
      window.__slackMessageReview?.close();
      try {
        if (!navigate)
          throw new Error("Slack conversation navigation is unavailable.");
        navigate(destination);
        show(false);
      } catch (error) {
        show(true);
        notice.textContent =
          error instanceof Error
            ? error.message
            : "The original conversation could not be opened. Retry this task.";
      }
    });
    return link;
  }

  function render(): void {
    if (stopped || !inWorkspace()) return;
    for (const [value, control] of filterButtons) {
      control.setAttribute("aria-pressed", String(filter === value));
      const count = tasks.filter((task) => matchesFilter(task, value)).length;
      const names: Record<string, string> = {
        all: "All tasks",
        approval: "Needs you",
        progress: "In progress",
        complete: "Completed",
      };
      control.textContent = `${names[value] ?? value} ${count}`;
    }
    const needsAttention = tasks.filter((task) =>
      attention.has(task.status),
    ).length;
    badge.hidden = needsAttention === 0;
    badge.textContent = String(needsAttention);
    railButton.setAttribute(
      "aria-label",
      needsAttention ? `Tasks, ${needsAttention} need your attention` : "Tasks",
    );
    const query = search.value.trim().toLocaleLowerCase();
    const visible = tasks
      .filter((task) => {
        const matches = matchesFilter(task, filter);
        return (
          matches &&
          `${task.title} ${task.conversation} ${task.original ?? ""}`
            .toLocaleLowerCase()
            .includes(query)
        );
      })
      .sort((a, b) => group(a) - group(b) || b.updatedAt - a.updatedAt);
    if (!visible.some((task) => task.id === selected)) selected = undefined;
    content.classList.toggle("inbox", selected === undefined);
    list.replaceChildren();
    if (selected)
      list.append(
        button(
          "View all tasks",
          () => {
            selected = undefined;
            render();
          },
          "back",
        ),
      );
    else {
      const introduction = element("div", "", "inbox-intro");
      introduction.append(
        element("strong", "Keep working across conversations."),
        element(
          "p",
          "Each conversation keeps one message review. Open it to choose a version, then send from Slack.",
          "muted",
        ),
      );
      list.append(introduction);
    }
    let previousGroup = -1;
    for (const task of visible) {
      const category = group(task);
      if (!selected && category !== previousGroup) {
        previousGroup = category;
        const names = ["Needs you", "In progress", "Earlier tasks"];
        list.append(
          element(
            "h3",
            `${names[category]} · ${visible.filter((entry) => group(entry) === category).length}`,
            "group-heading",
          ),
        );
      }
      const row = button(
        "",
        () => {
          selected = task.id;
          notice.textContent = "";
          render();
        },
        "row",
      );
      row.setAttribute("aria-current", String(selected === task.id));
      row.append(
        statusBadge(task),
        element("strong", task.title),
        element(
          "span",
          `${task.kind === "review" ? "Message review" : "Thread summary"} · ${task.conversation}${task.kind === "review" && !["handed-to-slack", "sending", "send-unknown"].includes(task.status) ? " · Not sent" : ""}`,
          "muted",
        ),
        element(
          "time",
          new Date(task.updatedAt).toLocaleTimeString([], {
            hour: "2-digit",
            minute: "2-digit",
          }),
          "row-time",
        ),
      );
      list.append(row);
    }
    detail.replaceChildren();
    detail.removeAttribute("aria-busy");
    const task = visible.find((entry) => entry.id === selected);
    const announcement = task
      ? `${task.title}: ${labels[task.status] ?? task.status}`
      : "";
    if (statusAnnouncement.textContent !== announcement)
      statusAnnouncement.textContent = announcement;
    if (!task) {
      if (visible.length) return;
      content.classList.remove("inbox");
      detail.append(
        element("h2", query ? "No matching tasks" : "No tasks here"),
        element(
          "p",
          "Message reviews and thread summaries will appear here.",
          "muted",
        ),
      );
      return;
    }
    detail.append(
      statusBadge(task),
      element("h2", task.title),
      element("p", task.conversation, "muted"),
    );
    if (task.progress) detail.append(element("p", task.progress));
    detail.setAttribute(
      "aria-busy",
      String(["running", "sending"].includes(task.status)),
    );
    if (task.error) section("Attention needed", task.error);
    if (task.coreQuestion)
      section("Question being answered", task.coreQuestion);
    if (task.assessment) section("Review assessment", task.assessment);
    const comparison = element("div", "", "comparison");
    if (task.original)
      section(
        ["handed-to-slack", "sending", "send-unknown"].includes(task.status)
          ? "Original message"
          : "Original message · Not sent",
        task.original,
      );
    if (task.suggestion) section("Suggested version", task.suggestion);
    if (task.original && task.suggestion) {
      const blocks = [
        ...detail.querySelectorAll<HTMLElement>(".section"),
      ].slice(-2);
      comparison.append(...blocks);
      detail.append(comparison);
    }
    if (task.summary) {
      const result = task.summary.summary;
      section("Summary", result.overview);
      if (result.decisions.length)
        section("Decisions", result.decisions.join("\n\n"));
      if (result.actions.length)
        section("Next steps", result.actions.join("\n\n"));
      if (result.actionDetails?.length) {
        section(
          "Owners and dates",
          result.actionDetails
            .map((action) =>
              [action.text, action.owner, action.due]
                .filter(Boolean)
                .join(" · "),
            )
            .join("\n\n"),
        );
      }
      if (result.openQuestions?.length)
        section("Still open", result.openQuestions.join("\n\n"));
      if (result.sources?.length) {
        const sources = element("section", "", "section");
        sources.append(element("h3", "Sources"));
        result.sources.forEach((source, index) => {
          const href = safeLink(source.url);
          if (href)
            sources.append(conversationLink(`Source ${index + 1}`, href));
        });
        detail.append(sources);
      }
      detail.append(
        element(
          "p",
          task.summary.saved
            ? "Saved to Tasks. Nothing posted to the thread."
            : "Not saved. The generated result is preserved.",
          "muted",
        ),
      );
    }
    const actions = element("div", "", "actions");
    if (
      task.kind === "review" &&
      window.__slackMessageReview?.has(task.id) &&
      !["completed", "handed-to-slack", "sending", "send-unknown"].includes(
        task.status,
      )
    ) {
      actions.append(
        button(
          "Open review",
          () => {
            const attempt = ++navigationAttempt;
            notice.textContent = "";
            if (!window.__slackMessageReview) {
              notice.textContent =
                "The original review is no longer available. Nothing was sent.";
              return;
            }
            show(false);
            void Promise.resolve(
              window.__slackMessageReview.open(task.id),
            ).catch((error: unknown) => {
              if (attempt !== navigationAttempt || selected !== task.id) return;
              show(true);
              notice.textContent =
                error instanceof Error
                  ? error.message
                  : "The original conversation could not be opened. Nothing was sent.";
            });
          },
          "primary",
        ),
      );
    }
    if (task.kind === "review" && task.status === "send-unknown") {
      section(
        "Check the conversation first",
        "Slack may have posted this message before the connection stopped. Confirm whether it appears in the conversation before trying again.",
      );
      actions.append(
        button("I confirmed it was posted", () =>
          notify({ kind: "resolve-send", id: task.id, sent: true }),
        ),
        button("Not posted · Review again", () =>
          notify({ kind: "resolve-send", id: task.id, sent: false }),
        ),
      );
    }
    if (task.url) {
      const url = safeLink(task.url);
      if (url)
        actions.append(
          conversationLink("Open conversation", url, task.destination),
        );
    }
    if (task.summary) {
      const result = task.summary.summary;
      actions.append(
        button("Copy summary", () => {
          void navigator.clipboard
            .writeText(
              [result.overview, ...result.decisions, ...result.actions].join(
                "\n\n",
              ),
            )
            .then(() => {
              notice.textContent = "Summary copied.";
            })
            .catch(() => {
              notice.textContent = "Could not copy the summary.";
            });
        }),
      );
    }
    if (
      !terminal.has(task.status) &&
      !["sending", "send-unknown"].includes(task.status)
    )
      actions.append(
        button(task.kind === "review" ? "Cancel review" : "Cancel task", () =>
          notify({ kind: "cancel", id: task.id }),
        ),
      );
    detail.append(actions);
    if (task.tools.length) {
      const tools = element("section", "", "section");
      tools.append(element("h3", "Tool activity"));
      for (const tool of task.tools) {
        const entry = element("details");
        const name =
          [tool.server, tool.tool].filter(Boolean).join(" · ") || tool.type;
        entry.append(
          element(
            "summary",
            `${name} · ${tool.status}${typeof tool.elapsedMs === "number" ? ` · ${(tool.elapsedMs / 1000).toFixed(1)}s` : ""}`,
          ),
          element("p", `Call ${tool.id}`, "muted"),
        );
        tools.append(entry);
      }
      detail.append(tools);
    }
  }

  function matchesFilter(task: TaskView, value: string): boolean {
    return (
      value === "all" ||
      (value === "approval" && attention.has(task.status)) ||
      (value === "progress" &&
        ["queued", "running", "sending"].includes(task.status)) ||
      (value === "complete" &&
        ["completed", "handed-to-slack"].includes(task.status))
    );
  }

  function group(task: TaskView): number {
    return matchesFilter(task, "approval")
      ? 0
      : matchesFilter(task, "progress")
        ? 1
        : 2;
  }

  const onKey = (event: KeyboardEvent) => {
    if (event.key === "Escape" && opened) {
      event.preventDefault();
      show(false);
    }
  };
  window.addEventListener("keydown", onKey);
  const timer = setInterval(() => {
    if (Date.now() - lastPulse > 15000) window.__slackAiTasks?.stop();
    else syncWorkspace();
  }, 5000);
  window.__slackAiTasks = {
    owner,
    pulse(id) {
      if (id !== owner) return false;
      lastPulse = Date.now();
      return true;
    },
    receive(value) {
      syncWorkspace();
      if (!inWorkspace()) return;
      tasks = value.filter((task) => task.workspaceId === workspaceId);
      render();
    },
    open(taskId) {
      syncWorkspace();
      if (!inWorkspace()) return;
      selected = taskId;
      filter = "all";
      search.value = "";
      show(true);
    },
    close() {
      show(false);
    },
    isOpen() {
      return opened;
    },
    stop() {
      stopped = true;
      clearInterval(timer);
      window.removeEventListener("keydown", onKey);
      window.removeEventListener("popstate", scheduleScan);
      window.removeEventListener("resize", scheduleScan);
      document.removeEventListener("click", onOutsideNavigation, true);
      observer.disconnect();
      railHost.remove();
      host.remove();
      delete window.__slackAiTasks;
    },
  };
  syncWorkspace();
})();
