import {
  keyHint,
  type ExtensionAPI,
  type ExtensionUIContext,
  type Theme,
  type ToolRenderers,
} from "@earendil-works/pi-coding-agent";
import {
  Container,
  getCapabilities,
  getImageDimensions,
  imageFallback,
  rgbColor,
  stripTerminalSequences,
  Text,
  truncateToWidth,
  type Component,
  type TuiMouseEvent,
} from "@earendil-works/pi-tui";

type RenderContext = Parameters<NonNullable<ToolRenderers["renderCall"]>>[2];

class MessageLine extends Container {
  private readonly prefix: string;
  private readonly padding: number;

  constructor(
    readonly content: Component,
    theme: Theme,
    context: RenderContext,
    display: Component = content,
    color: "warning" | "error" | "dim" = context.isPartial
      ? "warning"
      : context.isError
        ? "error"
        : "dim",
  ) {
    super();
    this.padding = context.outputPad;
    this.prefix = " ".repeat(this.padding) + theme.fg(color, "┃ ");
    this.addChild(display);
  }

  render(width: number): string[] {
    return super
      .render(Math.max(1, width - this.padding * 2 - 2))
      .map((line) => truncateToWidth(this.prefix + line, width, ""));
  }

  handleMouse(event: TuiMouseEvent) {
    if (event.x < this.padding + 2) {
      return undefined;
    }

    return super.handleMouse({
      ...event,
      x: event.x - this.padding - 2,
      width: Math.max(1, event.width - this.padding * 2 - 2),
    });
  }
}

function rendererContext(context: RenderContext): RenderContext {
  // Preserve the component identity expected by the wrapped renderer.
  return {
    ...context,
    outputPad: 0,
    lastComponent:
      context.lastComponent instanceof MessageLine
        ? context.lastComponent.content
        : context.lastComponent,
  };
}

// Preserve Pi's generic preview because its fallback renderer is not exported.
// https://github.com/earendil-works/pi/blob/main/packages/coding-agent/src/modes/interactive/components/tool-execution.ts
const renderFallbackResult: NonNullable<ToolRenderers["renderResult"]> = (
  result,
  options,
  theme,
  context,
) => {
  const output = result.content
    .flatMap((block) => {
      if (block.type === "text") {
        return [stripTerminalSequences(block.text).replace(/\r/g, "")];
      }
      if (
        block.type === "image" &&
        (!getCapabilities().images || !context.showImages)
      ) {
        return [
          imageFallback(
            block.mimeType,
            getImageDimensions(block.data, block.mimeType) ?? undefined,
          ),
        ];
      }
      return [];
    })
    .join("\n");
  if (!output) {
    return new Container();
  }

  const lines = output.split("\n");
  const visibleLines = options.expanded ? lines : lines.slice(0, 10);
  let text = visibleLines
    .map((line) => theme.fg("toolOutput", line))
    .join("\n");
  if (visibleLines.length < lines.length) {
    text += theme.fg(
      "muted",
      `\n... (${lines.length - visibleLines.length} more lines, `,
    );
    text += keyHint("app.tools.expand", "to expand") + theme.fg("muted", ")");
  }
  return new Text(text, 0, 0);
};

export default function messageLines(pi: ExtensionAPI) {
  let ui: ExtensionUIContext | undefined;
  let fixedTheme: Theme | undefined;
  let themeUpdateQueued = false;

  function scheduleTheme() {
    if (
      !ui ||
      !fixedTheme ||
      ui.theme.fg === fixedTheme.fg ||
      themeUpdateQueued
    ) {
      return;
    }

    // Defer invalidation until rendering finishes, including after Pi reloads its theme.
    themeUpdateQueued = true;
    queueMicrotask(() => {
      themeUpdateQueued = false;
      if (ui && fixedTheme && ui.theme.fg !== fixedTheme.fg) {
        ui.setTheme(fixedTheme);
      }
    });
  }

  pi.on("session_start", (_event, context) => {
    if (!context.hasUI) {
      return;
    }

    const name = context.ui.theme.name;
    const baseTheme = name ? context.ui.getTheme(name) : undefined;
    if (!baseTheme) {
      context.ui.notify(
        "Cannot load the current theme for transparent messages.",
        "error",
      );
      return;
    }

    // Capture a real theme instance; ui.theme is a proxy to the active theme.
    fixedTheme = Object.create(baseTheme) as Theme;
    fixedTheme.fg = (color, text) => {
      if (color === "mdQuoteBorder") {
        return baseTheme.fg(color, text.replaceAll("│", ">"));
      }
      if (name === "dark" && color === "thinkingText") {
        return baseTheme.style(text, {
          fg: rgbColor(176, 176, 176),
        });
      }
      return baseTheme.fg(color, text);
    };
    fixedTheme.bg = (color, text) =>
      color === "userMessageBg" ||
      color === "toolPendingBg" ||
      color === "toolSuccessBg" ||
      color === "toolErrorBg" ||
      color === "customMessageBg"
        ? `\x1b[49m${text}`
        : baseTheme.bg(color, text);
    ui = context.ui;
    scheduleTheme();
  });

  pi.on("session_shutdown", () => {
    ui = undefined;
  });

  pi.registerMarkdownTransformer((markdown, context) => {
    // Reapply transparent backgrounds after theme reloads.
    scheduleTheme();
    if (context.messageType !== "user") {
      return markdown;
    }
    return markdown
      .split("\n")
      .map((line) => `> ${line}`)
      .join("\n");
  });

  pi.registerToolRenderer((toolName, next) => {
    const renderers = next();
    return {
      renderShell: "self",
      renderCall(args, theme, context) {
        let content: Component;
        if (renderers?.renderCall) {
          content = renderers.renderCall(args, theme, rendererContext(context));
        } else {
          // Follow Pi's generic argument display for tools without a renderer.
          // https://github.com/earendil-works/pi/blob/main/packages/coding-agent/src/core/tools/render-utils.ts
          const entries =
            args == null
              ? []
              : typeof args === "object" && !Array.isArray(args)
                ? Object.entries(args)
                : [["args", args]];
          let text = theme.fg("toolTitle", theme.bold(toolName));
          if (entries.length > 0) {
            if (context.expanded) {
              text +=
                "\n" +
                theme.fg(
                  "muted",
                  entries
                    .map(([key, value]) => {
                      const valueText =
                        typeof value === "string"
                          ? value
                          : (JSON.stringify(value, null, 2) ?? String(value));
                      return `  ${key}: ${valueText.replace(/\t/g, "   ").replace(/\r/g, "").split("\n").join("\n    ")}`;
                    })
                    .join("\n"),
                );
            } else {
              const preview = entries
                .map(([key, value]) => `${key}=${JSON.stringify(value)}`)
                .join(" ");
              text +=
                " " +
                theme.fg(
                  "muted",
                  preview.length > 100 ? preview.slice(0, 97) + "..." : preview,
                );
            }
          }
          content = new Text(text, 0, 0);
        }
        return new MessageLine(
          content,
          theme,
          context,
          !context.isPartial && !context.expanded ? new Container() : content,
        );
      },
      renderResult(result, options, theme, context) {
        const content = (renderers?.renderResult ?? renderFallbackResult)(
          result,
          options,
          theme,
          rendererContext(context),
        );
        if (
          toolName !== "subagent" &&
          !context.isPartial &&
          !options.expanded
        ) {
          const calls =
            toolName === "codemode"
              ? (
                  result.details as
                    | {
                        calls?: {
                          status: "running" | "ok" | "error" | "cancelled";
                          error?: string;
                        }[];
                      }
                    | undefined
                )?.calls
              : undefined;
          // A script can catch a failed call and still return a successful result.
          const failed =
            context.isError || calls?.some((call) => call.status === "error");
          const cancelled = calls?.some((call) => call.status === "cancelled");
          const unfinished = calls?.some((call) => call.status === "running");
          let summary: string | undefined;
          pi.events.emit("tool-summaries:get", {
            toolCallId: context.toolCallId,
            reply: (text: string | undefined) => {
              summary = text;
            },
          });
          const name = stripTerminalSequences(summary ?? toolName).replace(
            /\s+/g,
            " ",
          );
          const elapsed =
            context.durationMs !== undefined
              ? ` · ${(context.durationMs / 1000).toFixed(1)}s`
              : "";
          if (!failed && !cancelled && !unfinished) {
            const count = calls ? ` · ${calls.length} calls` : "";
            const label =
              theme.fg("success", "✓ ") +
              theme.fg("text", name) +
              theme.fg(
                "muted",
                `${count}${elapsed} ${keyHint("app.tools.expand", "details")}`,
              );
            return new MessageLine(content, theme, context, {
              render: (width) => [truncateToWidth(label, width, "…")],
              invalidate() {},
            });
          }

          const counts = Object.entries({
            ok: "completed",
            error: "failed",
            cancelled: "cancelled",
            running: "incomplete",
          })
            .map(([status, label]) => {
              const count =
                calls?.filter((call) => call.status === status).length ?? 0;
              return count ? `${count} ${label}` : "";
            })
            .filter(Boolean)
            .join(", ");
          const label =
            theme.fg(failed ? "error" : "warning", `${failed ? "✗" : "■"} `) +
            theme.fg("text", name) +
            theme.fg(
              failed ? "error" : "warning",
              ` · ${failed ? "failed" : cancelled ? "cancelled" : "incomplete"}`,
            ) +
            theme.fg(
              "muted",
              `${counts ? ` · ${counts}` : ""}${elapsed} ${keyHint("app.tools.expand", "details")}`,
            );
          // Prefer the failed call's error over a generic script-output heading.
          const diagnostic = stripTerminalSequences(
            calls?.find((call) => call.status === "error" && call.error)
              ?.error ??
              result.content
                .filter((block) => block.type === "text")
                .map((block) => block.text)
                .join("\n"),
          )
            .split(/\r?\n/)
            .map((line) => line.trim())
            .find((line) => line && line !== "Script error:")
            ?.replace(/\s+/g, " ");
          const lines = [label];
          if (diagnostic)
            lines.push(theme.fg(failed ? "error" : "warning", diagnostic));
          const display: Component = {
            render: (width) =>
              lines.map((line) =>
                truncateToWidth(line, Math.max(1, Math.min(width, 120)), "…"),
              ),
            invalidate() {},
          };
          return new MessageLine(
            content,
            theme,
            context,
            display,
            failed ? "error" : "warning",
          );
        }
        return new MessageLine(content, theme, context);
      },
    };
  });
}
