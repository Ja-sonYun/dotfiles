import { basename } from "node:path";
import {
  ExtensionSelectorComponent,
  keyHint,
  type ExtensionContext,
} from "@earendil-works/pi-coding-agent";
import {
  Container,
  stripTerminalSequences,
  Text,
  truncateToWidth,
} from "@earendil-works/pi-tui";

export interface PermissionPrompt {
  options: string[];
  call: {
    toolCallId?: string;
    toolName: string;
    input: Record<string, unknown>;
  };
  actor: { name: string; mode: string; cwd: string };
  reasons: string[];
  signal: AbortSignal;
  context: ExtensionContext;
}

function previewText(value: unknown): string {
  const text =
    typeof value === "string"
      ? value
      : (JSON.stringify(value) ?? String(value));
  return stripTerminalSequences(text).replace(/\s+/g, " ").trim();
}

export async function showPermission(
  request: PermissionPrompt,
  summary: { text?: string },
): Promise<string | undefined> {
  if (request.signal.aborted) {
    return undefined;
  }
  return request.context.ui.custom<string | undefined>(
    (tui, theme, _keys, done) => {
      let closed = false;
      let expanded = false;
      const content = new Container();
      const header = {
        render(width: number) {
          const cwd = theme.fg(
            "muted",
            `Working directory: ${previewText(request.actor.cwd)}`,
          );
          const tool = theme.fg(
            "accent",
            theme.bold(previewText(request.call.toolName)),
          );
          const hint = theme.fg(
            "muted",
            keyHint(
              "app.tools.expand",
              expanded ? "hide details" : "show command and details",
            ),
          );
          if (expanded) {
            return new Text(
              [
                cwd,
                tool +
                  " " +
                  theme.fg(
                    "text",
                    stripTerminalSequences(
                      JSON.stringify(request.call.input, null, 2),
                    ),
                  ),
                ...request.reasons.map((reason) =>
                  theme.fg(
                    reason.startsWith("allow:")
                      ? "success"
                      : reason.startsWith("deny:")
                        ? "error"
                        : "warning",
                    stripTerminalSequences(reason),
                  ),
                ),
                hint,
              ].join("\n"),
              1,
              0,
            ).render(width);
          }

          let description = summary.text
            ? ` · ${previewText(summary.text)}`
            : ` · ${previewText(request.call.input)}`;
          const targetRows: string[] = [];
          const path =
            typeof request.call.input.path === "string"
              ? request.call.input.path
              : ["read", "ls", "find", "grep", "write", "edit"].includes(
                    request.call.toolName,
                  )
                ? request.actor.cwd
                : undefined;
          if (path !== undefined) {
            targetRows.push(
              theme.fg(
                "text",
                `Target: ${previewText(basename(path))} · ${previewText(path)}`,
              ),
            );
          } else if (typeof request.call.input.command === "string") {
            targetRows.push(
              theme.fg(
                "text",
                `Command: ${previewText(request.call.input.command)}`,
              ),
            );
          }
          const taskRows: string[] = [];
          const taskLimit = 3 - targetRows.length;
          if (request.call.toolName === "subagent") {
            if (
              typeof request.call.input.action === "string" &&
              request.call.input.action !== "run"
            ) {
              description = ` · ${previewText(request.call.input.action)} ${previewText(request.call.input.runId ?? "all")}`;
            } else {
              const tasks =
                Array.isArray(request.call.input.chain) &&
                request.call.input.chain.length > 0
                  ? request.call.input.chain
                  : Array.isArray(request.call.input.tasks) &&
                      request.call.input.tasks.length > 0
                    ? request.call.input.tasks
                    : [
                        {
                          agent: request.call.input.agent,
                          task: request.call.input.task,
                          cwd: request.call.input.cwd,
                        },
                      ];
              const mode =
                Array.isArray(request.call.input.chain) &&
                request.call.input.chain.length > 0
                  ? "chain"
                  : Array.isArray(request.call.input.tasks) &&
                      request.call.input.tasks.length > 0
                    ? "parallel"
                    : "single";
              description = ` · ${mode} · ${tasks.length} tasks · ${request.call.input.background === false ? "foreground" : "background"}`;
              if (request.call.input.agentScope !== undefined) {
                description += ` · scope ${previewText(request.call.input.agentScope)}`;
              }
              if (request.call.input.confirmProjectAgents === false) {
                description += " · project confirmation off";
              }
              for (const task of tasks.slice(0, taskLimit)) {
                const text =
                  task && typeof task === "object"
                    ? `${previewText(task.agent ?? "")} ${task.cwd ? `· cwd ${previewText(task.cwd)} ` : ""}· ${previewText(task.task ?? "")}`
                    : previewText(task);
                taskRows.push(theme.fg("text", `  ${text}`));
              }
              if (tasks.length > taskLimit) {
                taskRows[taskLimit - 1] = theme.fg(
                  "muted",
                  `  +${tasks.length - taskLimit + 1} more tasks`,
                );
              }
            }
          }

          const reasons = [
            ...new Set(
              request.reasons.filter((reason) => !reason.startsWith("allow:")),
            ),
          ];
          const reasonRows = reasons
            .slice(0, 2)
            .map((reason) =>
              theme.fg(
                reason.startsWith("deny:") ? "error" : "warning",
                previewText(reason),
              ),
            );
          if (reasons.length > 2) {
            reasonRows[1] = theme.fg(
              "muted",
              `+${reasons.length - 1} more reasons`,
            );
          }
          return [
            cwd,
            tool + theme.fg("muted", description),
            ...targetRows,
            ...taskRows,
            ...reasonRows,
            hint,
          ].map(
            (line) =>
              " " +
              truncateToWidth(line, Math.max(1, Math.min(width - 2, 120)), "…"),
          );
        },
        invalidate() {},
      };
      const finish = (choice?: string) => {
        if (closed) {
          return;
        }
        closed = true;
        request.signal.removeEventListener("abort", cancel);
        done(choice);
      };
      const cancel = () => finish();
      const update = () => {
        if (closed || request.signal.aborted) {
          return;
        }
        tui.requestRender();
      };
      const selector = new ExtensionSelectorComponent(
        `Permission: ${stripTerminalSequences(request.actor.name)} (${stripTerminalSequences(request.actor.mode)})`,
        request.options,
        finish,
        cancel,
        {
          tui,
          onToggleToolsExpanded: () => {
            expanded = !expanded;
            update();
          },
        },
      );
      content.addChild(header);
      content.addChild(selector);
      request.signal.addEventListener("abort", cancel, { once: true });
      if (request.signal.aborted) {
        queueMicrotask(cancel);
      } else {
        update();
      }
      return {
        render: (width) => content.render(width),
        invalidate: () => content.invalidate(),
        handleInput: (data) => selector.handleInput(data),
        dispose() {
          closed = true;
          request.signal.removeEventListener("abort", cancel);
          selector.dispose();
        },
      };
    },
  );
}
