import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import type { Component } from "@earendil-works/pi-tui";

import type { HookEventName } from "./hook-contract.ts";

export type HookCallStatus = "blocked" | "failed" | "succeeded";

export type HookCallEntry = {
  readonly detail?: string;
  readonly eventName: HookEventName;
  readonly status: HookCallStatus;
};

const entryType = "pi-hook-call";

class HookCallLine implements Component {
  constructor(private readonly line: (width: number) => string) {}

  render(width: number): string[] {
    return [this.line(width)];
  }
}

export const registerHookUI = (pi: ExtensionAPI): void => {
  pi.registerEntryRenderer<HookCallEntry>(
    entryType,
    (entry, _options, theme) => {
      const call = entry.data;
      if (call === undefined) {
        return undefined;
      }
      const detail = call.detail === undefined ? "" : `: ${call.detail}`;
      const text = `${call.eventName} hook ${call.status}${detail}`;
      const color =
        call.status === "succeeded"
          ? "success"
          : call.status === "blocked"
            ? "warning"
            : "error";
      return new HookCallLine((width) => {
        if (width < 1) {
          return "";
        }
        const marker = theme.fg("dim", "⎿");
        return width === 1
          ? marker
          : `${marker} ${theme.fg(color, text.slice(0, width - 2))}`;
      });
    },
  );
};

export const appendHookCall = (
  pi: ExtensionAPI,
  entry: HookCallEntry,
): void => {
  pi.appendEntry(entryType, entry);
};
