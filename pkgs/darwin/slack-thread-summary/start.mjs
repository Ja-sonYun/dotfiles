import { mkdir, readFile } from "node:fs/promises";
import { randomUUID } from "node:crypto";
import { setTimeout as delay } from "node:timers/promises";
import { summarize } from "./summarize.mjs";
import { SummaryStore, threadKey } from "./store.mjs";

const endpoint = "http://127.0.0.1:9222";
const timeline = await readFile(
  new URL("./timeline.js", import.meta.url),
  "utf8",
);
const source = (
  await readFile(new URL("./hook.js", import.meta.url), "utf8")
).replace("/* @timeline@ */ null", () => timeline.trim().replace(/;$/, ""));
const lifecycle = new AbortController();
process.on("SIGINT", () => lifecycle.abort());
process.on("SIGTERM", () => lifecycle.abort());

for (const name of [
  "SLACK_THREAD_SUMMARY_AGY",
  "SLACK_THREAD_SUMMARY_MODEL",
  "SLACK_THREAD_SUMMARY_PROMPT_FILE",
  "SLACK_THREAD_SUMMARY_STATE_DIRECTORY",
]) {
  if (!process.env[name]) throw new Error(`Missing service setting: ${name}`);
}
const prompt = await readFile(
  process.env.SLACK_THREAD_SUMMARY_PROMPT_FILE,
  "utf8",
);
if (!prompt.trim()) throw new Error("The summary prompt is empty.");
await mkdir(process.env.SLACK_THREAD_SUMMARY_STATE_DIRECTORY, {
  recursive: true,
  mode: 0o700,
});
const summaries = new SummaryStore(
  process.env.SLACK_THREAD_SUMMARY_STATE_DIRECTORY,
);
const listeners = new Set();

async function connect(target) {
  const owner = randomUUID();
  const hook = source.replace("@controllerId@", owner);
  const websocket = new WebSocket(target.webSocketDebuggerUrl);
  const requests = new Map();
  const jobs = new Set();
  let sequence = 0;
  const active = new Map();
  const threadJobs = new Map();
  const subscriptions = new Map();
  let stopping = false;
  let installedScript;
  let bindingInstalled = false;
  let heartbeat;
  let heartbeatBusy = false;
  let finish;
  const ended = new Promise((resolve) => {
    finish = resolve;
  });
  const abort = () => {
    cancelAll("Service stopped.");
    finish();
  };
  lifecycle.signal.addEventListener("abort", abort, { once: true });

  function call(method, params = {}) {
    const id = ++sequence;
    return new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        requests.delete(id);
        reject(new Error(`CDP timeout: ${method}`));
      }, 3000);
      requests.set(id, { resolve, reject, timeout });
      try {
        websocket.send(JSON.stringify({ id, method, params }));
      } catch (error) {
        clearTimeout(timeout);
        requests.delete(id);
        reject(error);
      }
    });
  }

  async function evaluate(expression, contextId) {
    const result = await call("Runtime.evaluate", {
      expression,
      returnByValue: true,
      ...(contextId === undefined ? {} : { contextId }),
    });
    if (result.exceptionDetails) {
      throw new Error(
        result.exceptionDetails.exception?.description ??
          result.exceptionDetails.text,
      );
    }
    return result.result.value;
  }

  function cancelAll(reason) {
    for (const session of active.values())
      session.controller.abort(new Error(reason));
    active.clear();
    threadJobs.clear();
  }

  async function publish(thread, card, deletedId) {
    const key = threadKey(thread);
    await Promise.allSettled(
      [...subscriptions]
        .filter(([, keys]) => keys.has(key))
        .map(([contextId]) =>
          evaluate(
            `window.__slackThreadSummary?.receiveCards(${JSON.stringify(thread)}, ${JSON.stringify(card ? [card] : [])}, ${JSON.stringify(deletedId ? [deletedId] : [])})`,
            contextId,
          ),
        ),
    );
  }
  listeners.add(publish);

  async function handleBinding(params) {
    if (params.name !== "__slackThreadSummaryBridge" || stopping) return;
    const request = JSON.parse(params.payload);
    if (typeof request.id !== "string") return;
    if (request.kind === "cancel") {
      const session = active.get(request.id);
      if (session?.contextId === params.executionContextId) {
        session.controller.abort(new Error("Summary cancelled."));
        active.delete(request.id);
        if (threadJobs.get(session.key) === session)
          threadJobs.delete(session.key);
      }
      return;
    }
    if (
      !["load", "save", "delete", "summarize"].includes(request.kind) ||
      active.has(request.id)
    )
      return;
    if (
      request.kind === "summarize" &&
      (!Array.isArray(request.messages) ||
        !request.messages.length ||
        !request.messages.every(
          (message) =>
            typeof message.author === "string" &&
            typeof message.text === "string",
        ))
    )
      return;

    const session = {
      id: request.id,
      controller: new AbortController(),
      contextId: params.executionContextId,
    };
    active.set(request.id, session);
    async function deliver(result) {
      if (
        active.get(request.id) !== session ||
        session.controller.signal.aborted
      )
        return;
      await evaluate(
        `window.__slackThreadSummary?.receive(${JSON.stringify(request.id)}, ${JSON.stringify(result)})`,
        session.contextId,
      ).catch((error) =>
        console.error(`Summary UI update unavailable: ${error.message}`),
      );
    }
    try {
      const key = threadKey(request.thread);
      const subscribed = subscriptions.get(session.contextId) ?? new Set();
      subscribed.add(key);
      subscriptions.set(session.contextId, subscribed);
      if (request.kind === "delete") {
        await summaries.delete(request.thread, request.cardId);
        await Promise.allSettled(
          [...listeners].map((listener) =>
            listener(request.thread, undefined, request.cardId),
          ),
        );
        await deliver({ deletedIds: [request.cardId] });
        return;
      }
      if (request.kind === "load") {
        const cards = await summaries.list(request.thread);
        const job = threadJobs.get(key);
        await deliver({
          cards,
          job: job && { id: job.id, progress: job.progress },
        });
        return;
      }
      if (request.kind === "summarize") {
        const job = threadJobs.get(key);
        if (job) {
          await deliver({ job: { id: job.id, progress: job.progress } });
          return;
        }
        session.key = key;
        session.progress = "Summarizing…";
        threadJobs.set(key, session);
      }
      if (
        request.kind === "summarize" &&
        (typeof request.throughTs !== "string" ||
          !/^\d+\.\d+$/.test(request.throughTs) ||
          request.throughTs < request.thread.threadTs)
      )
        throw new Error("The summary boundary is unavailable.");

      let card;
      if (request.kind === "save") {
        card = summaries.pending(request.thread, request.cardId);
      } else {
        const result = await summarize(
          request.messages,
          request.location,
          session.controller.signal,
          prompt,
          (progress) => {
            session.progress = progress;
            return deliver({ progress });
          },
        );
        session.controller.signal.throwIfAborted();
        card = {
          id: randomUUID(),
          throughTs: request.throughTs,
          generatedAt: new Date().toISOString(),
          count: request.messages.length,
          summary: result,
        };
      }
      let saved = true;
      let saveError;
      try {
        await summaries.save(request.thread, card);
      } catch (error) {
        saved = false;
        saveError = `Summary not saved: ${error.message}. Use Retry save; no new AI call is needed.`;
      }
      const entry = { ...card, saved };
      if (threadJobs.get(session.key) === session)
        threadJobs.delete(session.key);
      await Promise.allSettled(
        [...listeners].map((listener) => listener(request.thread, entry)),
      );
      await deliver({ cards: [entry], saveError });
    } catch (error) {
      if (!session.controller.signal.aborted) {
        if (threadJobs.get(session.key) === session)
          threadJobs.delete(session.key);
        console.error(error.message);
        await deliver({ error: error.message });
      }
    } finally {
      session.controller.abort();
      if (active.get(request.id) === session) active.delete(request.id);
      if (threadJobs.get(session.key) === session)
        threadJobs.delete(session.key);
    }
  }

  websocket.addEventListener("message", (event) => {
    const message = JSON.parse(event.data);
    if (message.id) {
      const pending = requests.get(message.id);
      if (!pending) return;
      clearTimeout(pending.timeout);
      requests.delete(message.id);
      if (message.error) pending.reject(new Error(message.error.message));
      else pending.resolve(message.result);
      return;
    }
    if (message.method === "Runtime.bindingCalled") {
      const job = handleBinding(message.params).catch((error) =>
        console.error(error.message),
      );
      jobs.add(job);
      void job.finally(() => jobs.delete(job));
    }
    if (message.method === "Runtime.executionContextsCleared") {
      subscriptions.clear();
      cancelAll("Slack page reloaded.");
    } else if (message.method === "Runtime.executionContextDestroyed") {
      subscriptions.delete(message.params.executionContextId);
      for (const [id, session] of active) {
        if (session.contextId === message.params.executionContextId) {
          session.controller.abort(new Error("Slack page reloaded."));
          active.delete(id);
          if (threadJobs.get(session.key) === session)
            threadJobs.delete(session.key);
        }
      }
    }
  });
  websocket.addEventListener("close", () => {
    cancelAll("Slack connection closed.");
    for (const pending of requests.values()) {
      clearTimeout(pending.timeout);
      pending.reject(new Error("Slack connection closed."));
    }
    requests.clear();
    finish();
  });

  try {
    await new Promise((resolve, reject) => {
      const timeout = setTimeout(
        () => reject(new Error("Slack CDP connection timed out.")),
        5000,
      );
      websocket.addEventListener(
        "open",
        () => {
          clearTimeout(timeout);
          resolve();
        },
        { once: true },
      );
      websocket.addEventListener(
        "error",
        () => {
          clearTimeout(timeout);
          reject(new Error("Slack CDP connection failed."));
        },
        { once: true },
      );
      websocket.addEventListener(
        "close",
        () => {
          clearTimeout(timeout);
          reject(new Error("Slack CDP connection closed."));
        },
        { once: true },
      );
    });
    lifecycle.signal.throwIfAborted();
    await call("Runtime.enable");
    await call("Page.enable");
    if (await evaluate("Boolean(window.__slackThreadSummary)")) {
      throw new Error(
        "A summary controller is already attached. Stop it before starting this service.",
      );
    }
    await call("Runtime.addBinding", { name: "__slackThreadSummaryBridge" });
    bindingInstalled = true;
    const script = await call("Page.addScriptToEvaluateOnNewDocument", {
      source: hook,
    });
    installedScript = script.identifier;
    await evaluate(hook);
    console.error("Slack thread summary ready.");
    heartbeat = setInterval(async () => {
      if (heartbeatBusy || stopping) return;
      heartbeatBusy = true;
      try {
        const result = await evaluate(
          `window.__slackThreadSummary?.pulse(${JSON.stringify(owner)}) ?? null`,
        );
        if (result === null) {
          await evaluate(hook);
        } else if (!result) {
          throw new Error("The summary hook belongs to another controller.");
        }
      } catch (error) {
        console.error(error.message);
        finish();
      } finally {
        heartbeatBusy = false;
      }
    }, 5000);
    await ended;
  } finally {
    stopping = true;
    listeners.delete(publish);
    subscriptions.clear();
    clearInterval(heartbeat);
    lifecycle.signal.removeEventListener("abort", abort);
    cancelAll("Summary connection stopped.");
    if (websocket.readyState === WebSocket.OPEN) {
      try {
        if (installedScript) {
          await call("Page.removeScriptToEvaluateOnNewDocument", {
            identifier: installedScript,
          });
        }
        // Remove only this controller's hook; another session may have attached meanwhile.
        await evaluate(
          `if (window.__slackThreadSummary?.owner === ${JSON.stringify(owner)}) window.__slackThreadSummary.stop()`,
        );
        if (bindingInstalled) {
          await call("Runtime.removeBinding", {
            name: "__slackThreadSummaryBridge",
          });
        }
      } catch (error) {
        console.error(
          `Hook cleanup interrupted; its lease expires automatically: ${error.message}`,
        );
      }
    }
    websocket.close();
    await Promise.allSettled([...jobs]);
  }
}

let lastStatus;
const connections = new Map();
let connectedOnce = false;
while (!lifecycle.signal.aborted) {
  try {
    const response = await fetch(`${endpoint}/json/list`, {
      signal: AbortSignal.any([lifecycle.signal, AbortSignal.timeout(5000)]),
    });
    if (!response.ok) throw new Error(`Slack CDP returned ${response.status}.`);
    const pages = (await response.json()).filter(
      (target) =>
        target.type === "page" &&
        target.url.startsWith("https://app.slack.com/"),
    );
    if (!pages.length) {
      if (connectedOnce && !connections.size) break;
      throw new Error("Waiting for a Slack window.");
    }
    lastStatus = undefined;
    connectedOnce = true;
    for (const page of pages) {
      if (connections.has(page.id)) continue;
      const connection = connect(page)
        .catch((error) => console.error(error.message))
        .finally(() => connections.delete(page.id));
      connections.set(page.id, connection);
    }
  } catch (error) {
    if (lifecycle.signal.aborted) break;
    if (
      connectedOnce &&
      !connections.size &&
      error.cause?.code === "ECONNREFUSED"
    )
      break;
    const message =
      error.cause?.code === "ECONNREFUSED"
        ? "Waiting for Slack debugging on 127.0.0.1:9222. If Slack is already running normally, quit and reopen it through this service."
        : error.message;
    if (message !== lastStatus) console.error(message);
    lastStatus = message;
  }
  await delay(5000, undefined, { signal: lifecycle.signal }).catch(() => {});
}
lifecycle.abort();
await Promise.allSettled([...connections.values()]);
