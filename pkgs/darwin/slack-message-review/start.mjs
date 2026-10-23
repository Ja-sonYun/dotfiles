import { mkdir, readFile } from "node:fs/promises";
import { randomUUID } from "node:crypto";
import { setTimeout as delay } from "node:timers/promises";
import { review } from "./review.mjs";
import { classify } from "./classify.mjs";

const endpoint = "http://127.0.0.1:9222";
const draftSource = await readFile(
  new URL("./draft.js", import.meta.url),
  "utf8",
);
const source = (
  await readFile(new URL("./hook.js", import.meta.url), "utf8")
).replace("/* @draft@ */ null", () => draftSource.trim().replace(/;$/, ""));
const lifecycle = new AbortController();
process.on("SIGINT", () => lifecycle.abort());
process.on("SIGTERM", () => lifecycle.abort());

for (const name of [
  "SLACK_REVIEW_AGY",
  "SLACK_REVIEW_JEV",
  "SLACK_REVIEW_MODEL",
  "SLACK_REVIEW_PROMPTS_FILE",
  "SLACK_REVIEW_STATE_DIRECTORY",
]) {
  if (!process.env[name]) throw new Error(`Missing service setting: ${name}`);
}
const prompts = JSON.parse(
  await readFile(process.env.SLACK_REVIEW_PROMPTS_FILE, "utf8"),
);
for (const name of ["classification", "review"]) {
  if (typeof prompts?.[name] !== "string") {
    throw new Error(`Invalid prompt setting: ${name}`);
  }
}
await mkdir(process.env.SLACK_REVIEW_STATE_DIRECTORY, {
  recursive: true,
  mode: 0o700,
});

async function connect(target) {
  const owner = randomUUID();
  const hook = source.replace("@controllerId@", owner);
  const websocket = new WebSocket(target.webSocketDebuggerUrl);
  const requests = new Map();
  const jobs = new Set();
  let sequence = 0;
  let active;
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
    cancelActive("Service stopped.");
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

  function cancelActive(reason) {
    active?.controller?.abort(new Error(reason));
    active = undefined;
  }

  async function handleBinding(params) {
    if (params.name !== "__slackReviewBridge" || stopping) return;
    const request = JSON.parse(params.payload);
    if (request.kind === "attached") {
      console.error(`Review connected: ${request.count} composer(s)`);
      return;
    }
    if (request.kind === "cancel") {
      if (active?.id === request.id) cancelActive(request.reason);
      return;
    }
    if (
      ["classify", "review"].includes(request.kind) &&
      typeof request.original === "string"
    ) {
      cancelActive("New review started.");
      active = {
        id: request.id,
        original: request.original,
        context: request.context,
        protectedElements: request.protectedElements ?? [],
        history: [],
        contextId: params.executionContextId,
        controller: undefined,
      };
    }
    const session = active;
    if (
      !session ||
      session.id !== request.id ||
      session.contextId !== params.executionContextId ||
      !["classify", "review", "ask"].includes(request.kind) ||
      session.controller
    )
      return;
    const controller = new AbortController();
    session.controller = controller;
    const input = {
      original: session.original,
      context: session.context,
      protectedElements: session.protectedElements,
      suggestion: request.suggestion ?? session.original,
      conversation: session.history,
      revisionRequest: request.instruction ?? "",
    };
    let result;
    try {
      if (request.kind === "classify") {
        result = await classify(
          { message: session.original, context: session.context },
          controller.signal,
          prompts.classification,
        );
        console.error("Jev classification:", JSON.stringify(result));
      } else {
        result = await review(input, controller.signal, prompts.review);
        session.history.push(
          {
            role: "user",
            instruction: input.revisionRequest,
            suggestion: input.suggestion,
          },
          { role: "assistant", ...result },
        );
      }
    } catch (error) {
      if (controller.signal.aborted) return;
      result = { error: error.message };
      console.error(error.message);
    } finally {
      session.controller = undefined;
    }
    if (active !== session || controller.signal.aborted) return;
    const receiver =
      request.kind === "classify" ? "receiveClassification" : "receive";
    await evaluate(
      `window.__slackMessageReview?.${receiver}(${JSON.stringify(request.id)}, ${JSON.stringify(request.turn)}, ${JSON.stringify(result)})`,
      session.contextId,
    );
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
    if (
      message.method === "Runtime.executionContextsCleared" ||
      (message.method === "Runtime.executionContextDestroyed" &&
        message.params.executionContextId === active?.contextId)
    ) {
      cancelActive("Slack page reloaded.");
    }
  });
  websocket.addEventListener("close", () => {
    cancelActive("Slack connection closed.");
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
    if (await evaluate("Boolean(window.__slackMessageReview)")) {
      throw new Error(
        "A review controller is already attached. Stop it before starting this service.",
      );
    }
    await call("Runtime.addBinding", { name: "__slackReviewBridge" });
    bindingInstalled = true;
    const script = await call("Page.addScriptToEvaluateOnNewDocument", {
      source: hook,
    });
    installedScript = script.identifier;
    await evaluate(hook);
    console.error("Slack review ready.");
    heartbeat = setInterval(async () => {
      if (heartbeatBusy || stopping) return;
      heartbeatBusy = true;
      try {
        const result = await evaluate(
          `window.__slackMessageReview?.pulse(${JSON.stringify(owner)}) ?? null`,
        );
        if (result === null) {
          await evaluate(hook);
        } else if (!result) {
          throw new Error("The review hook belongs to another controller.");
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
    clearInterval(heartbeat);
    lifecycle.signal.removeEventListener("abort", abort);
    cancelActive("Review connection stopped.");
    if (websocket.readyState === WebSocket.OPEN) {
      try {
        if (installedScript) {
          await call("Page.removeScriptToEvaluateOnNewDocument", {
            identifier: installedScript,
          });
        }
        // Remove only this controller's hook; another session may have attached meanwhile.
        await evaluate(
          `if (window.__slackMessageReview?.owner === ${JSON.stringify(owner)}) window.__slackMessageReview.stop()`,
        );
        if (bindingInstalled) {
          await call("Runtime.removeBinding", { name: "__slackReviewBridge" });
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
