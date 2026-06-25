import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import {
  Box,
  Text,
  visibleWidth,
  wrapTextWithAnsi,
} from "@earendil-works/pi-tui";

const BOX_ORIGINAL_RENDER = Symbol.for(
  "jay.pi.section-bars.box-original-render",
);
const TEXT_ORIGINAL_RENDER = Symbol.for(
  "jay.pi.section-bars.text-original-render",
);
const THEME_ORIGINAL_BG = Symbol.for("jay.pi.section-bars.theme-original-bg");

const BAR = "┃";
const BAR_AND_GAP_WIDTH = 2;

type ThemeColor = "borderAccent" | "success" | "error" | "warning" | "accent";
type ThemeLike = {
  fg(color: ThemeColor, text: string): string;
};

type BgFn = (text: string) => string;
type RenderFn<T> = (this: T, width: number) => string[];

type BoxInternals = Box & {
  children?: Array<{ render(width: number): string[] }>;
  paddingY?: number;
  bgFn?: BgFn;
};

type TextInternals = Text & {
  text?: string;
  paddingY?: number;
  customBgFn?: BgFn;
};

type PatchedBoxPrototype = typeof Box.prototype & {
  [BOX_ORIGINAL_RENDER]?: RenderFn<Box>;
};

type PatchedTextPrototype = typeof Text.prototype & {
  [TEXT_ORIGINAL_RENDER]?: RenderFn<Text>;
};

type PatchedThemePrototype = {
  [THEME_ORIGINAL_BG]?: (color: string, text: string) => string;
  bg?: (color: string, text: string) => string;
};

declare global {
  // Captured from ExtensionContext; importing pi's internal theme module is intentionally avoided.
  // eslint-disable-next-line no-var
  var __PI_SECTION_BARS_THEME__: ThemeLike | undefined;
  // eslint-disable-next-line no-var
  var __PI_SECTION_BARS_THEME_PROTO__: PatchedThemePrototype | undefined;
}

function padToWidth(line: string, width: number): string {
  return line + " ".repeat(Math.max(0, width - visibleWidth(line)));
}

function colorForBackground(bgFn: BgFn | undefined): ThemeColor {
  const source = String(bgFn ?? "");
  if (source.includes("toolErrorBg")) return "error";
  if (source.includes("toolSuccessBg")) return "success";
  if (source.includes("toolPendingBg")) return "warning";
  if (source.includes("selectedBg")) return "accent";
  return "borderAccent";
}

function coloredBar(bgFn: BgFn | undefined): string {
  try {
    const color = colorForBackground(bgFn);
    return globalThis.__PI_SECTION_BARS_THEME__?.fg(color, BAR) ?? BAR;
  } catch {
    return BAR;
  }
}

function formatBarLine(
  bar: string,
  content: string | undefined,
  width: number,
): string {
  if (width <= 1) return bar;
  const line = content === undefined ? bar : `${bar} ${content}`;
  return padToWidth(line, width);
}

function renderBoxWithBars(this: Box, width: number): string[] {
  const proto = Box.prototype as PatchedBoxPrototype;
  const originalRender = proto[BOX_ORIGINAL_RENDER];
  const box = this as BoxInternals;

  if (!box.bgFn || !box.children || box.children.length === 0) {
    return originalRender ? originalRender.call(this, width) : [];
  }

  const safeWidth = Math.max(1, width);
  const contentWidth = Math.max(1, safeWidth - BAR_AND_GAP_WIDTH);
  const childLines: string[] = [];

  for (const child of box.children) {
    for (const line of child.render(contentWidth)) {
      childLines.push(line);
    }
  }

  if (childLines.length === 0) {
    return [];
  }

  const bar = coloredBar(box.bgFn);
  const paddingY = Math.max(0, box.paddingY ?? 0);
  const result: string[] = [];

  for (let i = 0; i < paddingY; i++) {
    result.push(formatBarLine(bar, undefined, safeWidth));
  }
  for (const line of childLines) {
    result.push(formatBarLine(bar, line, safeWidth));
  }
  for (let i = 0; i < paddingY; i++) {
    result.push(formatBarLine(bar, undefined, safeWidth));
  }

  return result;
}

function renderTextWithBars(this: Text, width: number): string[] {
  const proto = Text.prototype as PatchedTextPrototype;
  const originalRender = proto[TEXT_ORIGINAL_RENDER];
  const text = this as TextInternals;

  if (!text.customBgFn) {
    return originalRender ? originalRender.call(this, width) : [];
  }

  const rawText = text.text ?? "";
  if (!rawText || rawText.trim() === "") {
    return [];
  }

  const safeWidth = Math.max(1, width);
  const contentWidth = Math.max(1, safeWidth - BAR_AND_GAP_WIDTH);
  const normalizedText = rawText.replace(/\t/g, "   ");
  const wrappedLines = wrapTextWithAnsi(normalizedText, contentWidth);
  const bar = coloredBar(text.customBgFn);
  const paddingY = Math.max(0, text.paddingY ?? 0);
  const result: string[] = [];

  for (let i = 0; i < paddingY; i++) {
    result.push(formatBarLine(bar, undefined, safeWidth));
  }
  for (const line of wrappedLines) {
    result.push(formatBarLine(bar, line, safeWidth));
  }
  for (let i = 0; i < paddingY; i++) {
    result.push(formatBarLine(bar, undefined, safeWidth));
  }

  return result;
}

function installRenderPatches(): void {
  const boxProto = Box.prototype as PatchedBoxPrototype;
  if (!boxProto[BOX_ORIGINAL_RENDER]) {
    boxProto[BOX_ORIGINAL_RENDER] = boxProto.render;
  }
  boxProto.render = renderBoxWithBars;

  const textProto = Text.prototype as PatchedTextPrototype;
  if (!textProto[TEXT_ORIGINAL_RENDER]) {
    textProto[TEXT_ORIGINAL_RENDER] = textProto.render;
  }
  textProto.render = renderTextWithBars;
}

function noBackground(_color: string, text: string): string {
  return text;
}

function installThemePatch(theme: ThemeLike): void {
  globalThis.__PI_SECTION_BARS_THEME__ = theme;

  const proto = Object.getPrototypeOf(theme) as PatchedThemePrototype;
  if (!proto || typeof proto.bg !== "function") return;

  globalThis.__PI_SECTION_BARS_THEME_PROTO__ = proto;
  if (!proto[THEME_ORIGINAL_BG]) {
    proto[THEME_ORIGINAL_BG] = proto.bg;
  }

  // Remove remaining direct background usage. Bars get color through fg() only.
  proto.bg = noBackground;
}

function uninstallPatches(): void {
  const boxProto = Box.prototype as PatchedBoxPrototype;
  const originalBoxRender = boxProto[BOX_ORIGINAL_RENDER];
  if (originalBoxRender && boxProto.render === renderBoxWithBars) {
    boxProto.render = originalBoxRender;
  }

  const textProto = Text.prototype as PatchedTextPrototype;
  const originalTextRender = textProto[TEXT_ORIGINAL_RENDER];
  if (originalTextRender && textProto.render === renderTextWithBars) {
    textProto.render = originalTextRender;
  }

  const themeProto = globalThis.__PI_SECTION_BARS_THEME_PROTO__;
  const originalBg = themeProto?.[THEME_ORIGINAL_BG];
  if (themeProto && originalBg && themeProto.bg === noBackground) {
    themeProto.bg = originalBg;
  }

  globalThis.__PI_SECTION_BARS_THEME__ = undefined;
  globalThis.__PI_SECTION_BARS_THEME_PROTO__ = undefined;
}

export default function (pi: ExtensionAPI) {
  installRenderPatches();

  pi.on("session_start", (_event, ctx) => {
    installThemePatch(ctx.ui.theme);
  });

  pi.on("session_shutdown", () => {
    uninstallPatches();
  });
}
