import {
  ExtensionSelectorComponent,
  keyHint,
  type ExtensionContext,
} from "@earendil-works/pi-coding-agent";
import { Container, Text } from "@earendil-works/pi-tui";

export interface PermissionPrompt {
  title: string;
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
  reply: (choice: Promise<string | undefined>) => void;
}

export async function showPermission(
  request: PermissionPrompt,
  summary: { text?: string; pending?: Promise<void> },
): Promise<string | undefined> {
  if (request.signal.aborted) {
    return undefined;
  }
  return request.context.ui.custom<string | undefined>(
    (tui, _theme, _keys, done) => {
      let closed = false;
      let expanded = false;
      const content = new Container();
      const header = new Text("", 1, 0);
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
        const reasons = [
          ...new Set(
            request.reasons.filter((reason) => !reason.startsWith("allow:")),
          ),
        ];
        header.setText(
          [
            expanded || !summary.text
              ? request.title
              : [
                  `Working directory: ${request.actor.cwd}`,
                  `${request.call.toolName}${summary.text ? ` · ${summary.text}` : ""}`,
                  ...reasons,
                ].join("\n"),
            ...(summary.text
              ? [
                  keyHint(
                    "app.tools.expand",
                    expanded ? "hide details" : "show command and details",
                  ),
                ]
              : []),
          ].join("\n"),
        );
        tui.requestRender();
      };
      const selector = new ExtensionSelectorComponent(
        `Permission: ${request.actor.name} (${request.actor.mode})`,
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
        void summary.pending?.then(update);
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
