/**
 * pi-btw — single-file local Pi extension.
 *
 * Derived from: https://github.com/tianrendong/pi-qq (main)
 * Renamed/refactored into one local file for ~/.pi/agent/extensions/ so it can be edited locally.
 *
 * MIT License
 * Copyright (c) 2026 pi-qq contributors
 * NOTICE: This package includes MIT-licensed portions copyright (c) 2026 juicesharp.
 */

import {
	type AssistantMessage,
	completeSimple,
	type Message,
	type StopReason,
	type UserMessage,
} from "@earendil-works/pi-ai";
import {
	buildSessionContext,
	convertToLlm,
	type ExtensionAPI,
	type ExtensionCommandContext,
	type ExtensionContext,
	type Theme,
} from "@earendil-works/pi-coding-agent";
import type { OverlayOptions } from "@earendil-works/pi-tui";
import {
	type Component,
	Key,
	matchesKey,
	type TUI,
	truncateToWidth,
	visibleWidth,
	wrapTextWithAnsi,
} from "@earendil-works/pi-tui";

export const BTW_COMMAND_NAME = "btw";
export const BTW_HISTORY_COMMAND_NAME = "btw-history";
export const BTW_PREFIX = `/${BTW_COMMAND_NAME} `;
export const BTW_STATE_KEY = Symbol.for("pi-btw:btw");

const MSG_REQUIRES_INTERACTIVE = "/btw requires interactive mode";
const MSG_USAGE = "Usage: /btw [--recent|--full] <question>";
const MSG_NO_MODEL = "/btw requires an active model";
const ERR_EMPTY_RESPONSE = "/btw returned no text content.";
const MSG_NO_HISTORY = "No /btw history for this session yet";
const BTW_HISTORY_LIMIT = 20;
const RECENT_CONTEXT_MESSAGE_LIMIT = 12;
const FULL_CONTEXT_HEAD_MESSAGE_LIMIT = 4;
const FULL_CONTEXT_TAIL_MESSAGE_LIMIT = 80;
const MAX_TEXT_CHARS_PER_PART = 4_000;

const BTW_SYSTEM_PROMPT = `You answer by-the-way side questions about the user's main pi session.

Default ambiguous references to the main session. "This", "that", "it", "we", "the plan", "the code", "the issue", and "what you were doing" refer to the primary conversation unless the user clearly says otherwise.

Treat the primary conversation as background only. You may receive recent context or broader bounded context. Do not continue prior work, resume tool calls, or start a task. Answer only the by-the-way question.

Optimize for speed and brevity. Answer in one short sentence by default. Use up to 3 terse bullets only when necessary. No preamble. No restating the question. No summary. If uncertain or missing context, say so in one short sentence.

Cite files/functions/lines only when necessary to ground a claim; otherwise skip citations.

You have no tools. Do not call tools. Plain text only.`;

const errMisconfigured = (label: string, err: string) => `/btw model (${label}) is misconfigured: ${err}`;
const errNoApiKey = (label: string) => `/btw model (${label}) has no API key available.`;
const errCallFailed = (err: string | undefined) => `/btw call failed: ${err ?? "unknown error"}`;
const errCallThrew = (msg: string) => `/btw call threw: ${msg}`;

type BtwContextMode = "recent" | "full";

type Mode = "pending" | "answer" | "error";

interface ParsedBtwArgs {
	question: string;
	mode: BtwContextMode;
}

interface BtwHistoryEntry {
	question: string;
	answer: string;
	timestamp: number;
}

interface BtwState {
	histories: Map<string, BtwHistoryEntry[]>;
}

interface BtwExecResult {
	ok: boolean;
	answer?: string;
	userMessage?: UserMessage;
	assistantMessage?: AssistantMessage;
	error?: string;
	stopReason?: StopReason;
	aborted?: boolean;
}

interface ShowBtwOverlayParams {
	ctx: ExtensionCommandContext;
	question: string;
	controller: AbortController;
	commandLabel?: string;
}

interface ShowBtwOverlayResult {
	overlayPromise: Promise<void>;
	controllerReady: Promise<BtwOverlayController>;
}

const BTW_OVERLAY_OPTIONS: OverlayOptions = {
	anchor: "bottom-center",
	width: "100%",
	maxHeight: "85%",
	margin: { left: 0, right: 0, bottom: 0 },
};

const BTW_MAX_HEIGHT_RATIO = 0.85;
const SIDE_PAD = "  ";
const ANSWER_PAD = "    ";
const BTW_LITERAL = "/btw";
const SPINNER_FRAMES = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"];
const SPINNER_INTERVAL_MS = 80;
const FOOTER_SCROLL = "↑/↓ to scroll";
const FOOTER_DISMISS = "Esc to dismiss";
const FOOTER_SEP = " · ";

function getState(): BtwState {
	const globalState = globalThis as unknown as { [k: symbol]: Partial<BtwState> | undefined };
	let state = globalState[BTW_STATE_KEY];
	if (!state) {
		state = {};
		globalState[BTW_STATE_KEY] = state;
	}
	state.histories ??= new Map();
	return state as BtwState;
}

function getSessionFile(ctx: ExtensionContext): string {
	return ctx.sessionManager.getSessionFile() ?? `memory:${ctx.sessionManager.getSessionId()}`;
}

function getSessionHistory(ctx: ExtensionContext): BtwHistoryEntry[] {
	const key = getSessionFile(ctx);
	const state = getState();
	let history = state.histories.get(key);
	if (!history) {
		history = [];
		state.histories.set(key, history);
	}
	return history;
}

function pushSessionHistory(ctx: ExtensionContext, entry: BtwHistoryEntry): void {
	const history = getSessionHistory(ctx);
	history.push(entry);
	if (history.length > BTW_HISTORY_LIMIT) {
		history.splice(0, history.length - BTW_HISTORY_LIMIT);
	}
}

function formatHistoryTimestamp(timestamp: number): string {
	return new Date(timestamp).toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" });
}

function formatBtwHistory(entries: BtwHistoryEntry[]): string {
	return entries
		.slice()
		.reverse()
		.map((entry, index) => {
			const question = entry.question.replace(/\s+/g, " ").trim();
			const answer = entry.answer.trim();
			return `${index + 1}. ${formatHistoryTimestamp(entry.timestamp)} — /btw ${question}\n${answer}`;
		})
		.join("\n\n");
}

function assistantMessageText(msg: AssistantMessage): string {
	return msg.content
		.filter((content): content is { type: "text"; text: string } => content.type === "text")
		.map((content) => content.text)
		.join("\n");
}

function clipText(text: string): string {
	if (text.length <= MAX_TEXT_CHARS_PER_PART) return text;
	return `${text.slice(0, MAX_TEXT_CHARS_PER_PART)}\n[…truncated for /btw speed…]`;
}

function contentPartsToText(content: Array<{ type: string }>): string {
	const parts: string[] = [];
	for (const part of content) {
		if (part.type === "text" && "text" in part && typeof part.text === "string") {
			parts.push(clipText(part.text));
		} else if (part.type === "image") {
			parts.push("[image omitted for /btw speed]");
		} else if (part.type === "toolCall" && "name" in part && typeof part.name === "string") {
			parts.push(`[assistant requested tool: ${part.name}]`);
		}
	}
	return parts.join("\n").trim();
}

function userContentToText(content: UserMessage["content"]): string {
	return typeof content === "string" ? clipText(content) : contentPartsToText(content);
}

function trimMessageForContext(message: Message): Message {
	if (message.role === "assistant") {
		const text = contentPartsToText(message.content) || "[assistant message omitted for /btw speed]";
		return { ...message, content: [{ type: "text", text }] };
	}
	if (message.role === "user") {
		return { ...message, content: [{ type: "text", text: userContentToText(message.content) }] };
	}
	const text = contentPartsToText(message.content) || "[tool result omitted for /btw speed]";
	return {
		role: "user",
		content: [{ type: "text", text: `[tool result: ${message.toolName}]\n${text}` }],
		timestamp: message.timestamp,
	};
}

function selectRecentContextMessages(messages: Message[]): Message[] {
	return messages.slice(-RECENT_CONTEXT_MESSAGE_LIMIT).map(trimMessageForContext);
}

function selectFullContextMessages(messages: Message[]): Message[] {
	if (messages.length <= FULL_CONTEXT_HEAD_MESSAGE_LIMIT + FULL_CONTEXT_TAIL_MESSAGE_LIMIT) {
		return messages.map(trimMessageForContext);
	}
	return [
		...messages.slice(0, FULL_CONTEXT_HEAD_MESSAGE_LIMIT),
		...messages.slice(-FULL_CONTEXT_TAIL_MESSAGE_LIMIT),
	].map(trimMessageForContext);
}

function selectContextMessages(messages: Message[], mode: BtwContextMode): Message[] {
	return mode === "full" ? selectFullContextMessages(messages) : selectRecentContextMessages(messages);
}

function parseBtwArgs(args: string): ParsedBtwArgs {
	const trimmed = args.trim();
	if (trimmed.startsWith("--recent ")) {
		return { mode: "recent", question: trimmed.slice("--recent ".length).trim() };
	}
	if (trimmed === "--recent") {
		return { mode: "recent", question: "" };
	}
	if (trimmed.startsWith("--full ")) {
		return { mode: "full", question: trimmed.slice("--full ".length).trim() };
	}
	if (trimmed === "--full") {
		return { mode: "full", question: "" };
	}
	return { mode: detectContextMode(trimmed), question: trimmed };
}

function includesAny(text: string, phrases: string[]): boolean {
	return phrases.some((phrase) => text.includes(phrase));
}

function detectContextMode(question: string): BtwContextMode {
	const normalized = question.toLowerCase();

	const recentPhrases = [
		"last turn",
		"previous turn",
		"last message",
		"latest",
		"just now",
		"what did we just",
		"right now",
		"current",
		"currently",
		"most recent",
		"the last thing",
	];
	if (includesAny(normalized, recentPhrases)) {
		return "recent";
	}

	const fullPhrases = [
		"entire session",
		"whole session",
		"this session",
		"from the beginning",
		"full context",
		"so far",
		"overall",
		"earlier",
		"previously",
		"at the start",
		"originally",
		"what have we done",
		"what did we decide",
		"summarize",
		"recap",
	];
	if (includesAny(normalized, fullPhrases)) {
		return "full";
	}

	return "recent";
}

function readCurrentContextMessages(ctx: ExtensionContext, mode: BtwContextMode): Message[] {
	// Always rebuild the canonical LLM context from the session manager's live
	// leaf. This is important after /tree navigation: the session file remains an
	// append-only tree, so reading all entries (or a cached post-turn snapshot)
	// can accidentally include messages from descendants that are no longer on
	// the active branch.
	const sessionContext = buildSessionContext(ctx.sessionManager.getEntries(), ctx.sessionManager.getLeafId());
	return selectContextMessages(convertToLlm(sessionContext.messages), mode);
}

function buildBtwMessages(ctx: ExtensionContext, userMessage: UserMessage, mode: BtwContextMode): Message[] {
	return [...readCurrentContextMessages(ctx, mode), userMessage];
}

async function executeBtw(
	question: string,
	mode: BtwContextMode,
	ctx: ExtensionContext,
	controller: AbortController,
): Promise<BtwExecResult> {
	const model = ctx.model;
	if (!model) {
		return { ok: false, error: MSG_NO_MODEL };
	}
	const modelLabel = `${model.provider}:${model.id}`;

	const auth = await ctx.modelRegistry.getApiKeyAndHeaders(model);
	if (!auth.ok) {
		return { ok: false, error: errMisconfigured(modelLabel, auth.error) };
	}
	if (!auth.apiKey) {
		return { ok: false, error: errNoApiKey(modelLabel) };
	}

	const userMessage: UserMessage = {
		role: "user",
		content: [{ type: "text", text: question }],
		timestamp: Date.now(),
	};

	try {
		const response = await completeSimple(
			model,
			{ systemPrompt: BTW_SYSTEM_PROMPT, messages: buildBtwMessages(ctx, userMessage, mode), tools: [] },
			{
				apiKey: auth.apiKey,
				headers: auth.headers,
				signal: controller.signal,
			},
		);

		if (response.stopReason === "aborted") {
			return { ok: false, aborted: true, stopReason: response.stopReason };
		}
		if (response.stopReason === "error") {
			return {
				ok: false,
				error: errCallFailed(response.errorMessage),
				stopReason: response.stopReason,
			};
		}

		const answerText = assistantMessageText(response).trim();
		if (!answerText) {
			return { ok: false, error: ERR_EMPTY_RESPONSE, stopReason: response.stopReason };
		}

		return {
			ok: true,
			answer: answerText,
			userMessage,
			assistantMessage: response,
			stopReason: response.stopReason,
		};
	} catch (err) {
		const message = err instanceof Error ? err.message : String(err);
		if (controller.signal.aborted) {
			return { ok: false, aborted: true };
		}
		return { ok: false, error: errCallThrew(message) };
	}
}

function registerBtwShortcut(pi: ExtensionAPI): void {
	pi.registerShortcut("alt+q", {
		description: "Toggle /btw side-question prefix",
		handler: async (ctx) => {
			if (!ctx.hasUI) return;
			const current = ctx.ui.getEditorText() ?? "";
			if (current.startsWith(BTW_PREFIX)) {
				ctx.ui.setEditorText(current.slice(BTW_PREFIX.length));
				return;
			}
			ctx.ui.setEditorText(BTW_PREFIX + current);
		},
	});
}

function registerBtwCommand(pi: ExtensionAPI): void {
	pi.registerCommand(BTW_COMMAND_NAME, {
		description: "Ask a by-the-way question without polluting the main conversation",
		handler: (args: string, ctx: ExtensionCommandContext) => handleBtwCommand(args, ctx),
	});
	pi.registerCommand(BTW_HISTORY_COMMAND_NAME, {
		description: "Show recent /btw answers for this session",
		handler: (_args: string, ctx: ExtensionCommandContext) => handleBtwHistoryCommand(ctx),
	});
}

async function handleBtwCommand(args: string, ctx: ExtensionCommandContext): Promise<void> {
	if (ctx.mode !== "tui") {
		ctx.ui.notify(MSG_REQUIRES_INTERACTIVE, "error");
		return;
	}
	const parsedArgs = parseBtwArgs(args);
	if (!parsedArgs.question) {
		ctx.ui.notify(MSG_USAGE, "warning");
		return;
	}
	if (!ctx.model) {
		ctx.ui.notify(MSG_NO_MODEL, "error");
		return;
	}

	const controller = new AbortController();
	const { overlayPromise, controllerReady } = showBtwOverlay({
		ctx,
		question: parsedArgs.question,
		controller,
	});

	const overlayCtl = await controllerReady;
	const result = await executeBtw(parsedArgs.question, parsedArgs.mode, ctx, controller);

	if (result.ok && result.answer) {
		pushSessionHistory(ctx, {
			question: parsedArgs.question,
			answer: result.answer,
			timestamp: Date.now(),
		});

		overlayCtl.setAnswer(result.answer);
	} else if (result.aborted) {
		// User Esc'd — overlay already dismissed via done(); no further action.
	} else if (result.error) {
		overlayCtl.setError(result.error);
	}

	await overlayPromise;
}

async function handleBtwHistoryCommand(ctx: ExtensionCommandContext): Promise<void> {
	if (ctx.mode !== "tui") {
		ctx.ui.notify(MSG_REQUIRES_INTERACTIVE, "error");
		return;
	}
	const history = getSessionHistory(ctx);
	if (history.length === 0) {
		ctx.ui.notify(MSG_NO_HISTORY, "info");
		return;
	}

	const controller = new AbortController();
	const { overlayPromise, controllerReady } = showBtwOverlay({
		ctx,
		question: `${history.length} recent answer${history.length === 1 ? "" : "s"}`,
		controller,
		commandLabel: "/btw-history",
	});

	const overlayCtl = await controllerReady;
	overlayCtl.setAnswer(formatBtwHistory(history));
	await overlayPromise;
}

class BtwOverlayController implements Component {
	private mode: Mode = "pending";
	private answer = "";
	private error = "";
	private scrollOffset = 0;
	private spinnerFrame = 0;
	private spinnerInterval: ReturnType<typeof setInterval> | undefined;

	constructor(
		private readonly question: string,
		private readonly theme: Theme,
		private readonly tui: TUI,
		private readonly done: (result?: undefined) => void,
		private readonly controller: AbortController,
		private readonly commandLabel: string = BTW_LITERAL,
	) {
		this.startSpinner();
		this.controller.signal.addEventListener("abort", () => this.stopSpinner(), { once: true });
	}

	private startSpinner(): void {
		this.stopSpinner();
		this.spinnerInterval = setInterval(() => {
			if (this.mode !== "pending") {
				this.stopSpinner();
				return;
			}
			this.spinnerFrame = (this.spinnerFrame + 1) % SPINNER_FRAMES.length;
			this.tui.requestRender();
		}, SPINNER_INTERVAL_MS);
	}

	private stopSpinner(): void {
		if (!this.spinnerInterval) return;
		clearInterval(this.spinnerInterval);
		this.spinnerInterval = undefined;
	}

	setAnswer(text: string): void {
		this.stopSpinner();
		this.mode = "answer";
		this.answer = text;
		this.tui.requestRender();
	}

	setError(message: string): void {
		this.stopSpinner();
		this.mode = "error";
		this.error = message;
		this.tui.requestRender();
	}

	handleInput(data: string): void {
		if (matchesKey(data, Key.escape)) {
			this.stopSpinner();
			this.controller.abort();
			this.done();
			return;
		}
		if (matchesKey(data, Key.up)) {
			this.scrollOffset = Math.max(0, this.scrollOffset - 1);
			this.tui.requestRender();
			return;
		}
		if (matchesKey(data, Key.down)) {
			this.scrollOffset = this.scrollOffset + 1;
			this.tui.requestRender();
			return;
		}
	}

	render(width: number): string[] {
		const banner = this.renderBanner(width);
		const answerLines = this.renderAnswer(width);
		const footerAvail = Math.max(1, width - SIDE_PAD.length);
		const footerParts: string[] = [];
		if (this.mode !== "pending") footerParts.push(FOOTER_SCROLL);
		footerParts.push(FOOTER_DISMISS);
		const footer =
			SIDE_PAD + truncateToWidth(this.theme.fg("dim", footerParts.join(FOOTER_SEP)), footerAvail, "…", false);

		const natural: string[] = [banner, "", ...answerLines, "", footer];

		const termRows = (this.tui.terminal as { rows?: number }).rows ?? 24;
		const maxRows = Math.max(4, Math.floor(termRows * BTW_MAX_HEIGHT_RATIO));
		if (natural.length <= maxRows) {
			return natural;
		}
		const excess = natural.length - maxRows;
		if (this.scrollOffset > excess) this.scrollOffset = excess;
		const start = excess - this.scrollOffset;
		return natural.slice(start, start + maxRows);
	}

	invalidate(): void {
		// Render recomputes from state each cycle.
	}

	private renderBanner(width: number): string {
		const prefix = `${SIDE_PAD}${this.commandLabel} `;
		const prefixWidth = visibleWidth(prefix);
		const questionWidth = Math.max(0, width - prefixWidth);
		const truncatedQuestion = truncateToWidth(this.question, questionWidth, "…", false);
		const raw = prefix + truncatedQuestion;
		const padded = raw + " ".repeat(Math.max(0, width - visibleWidth(raw)));
		return this.theme.bg("customMessageBg", this.theme.fg("customMessageText", padded));
	}

	private renderAnswer(width: number): string[] {
		const bodyWidth = Math.max(1, width - ANSWER_PAD.length);
		const indent = (lines: string[]) => lines.map((line) => ANSWER_PAD + line);

		if (this.mode === "pending") {
			const frame = SPINNER_FRAMES[this.spinnerFrame] ?? SPINNER_FRAMES[0]!;
			return indent([this.theme.fg("accent", frame)]);
		}
		if (this.mode === "error") {
			const out: string[] = [];
			for (const line of this.error.split("\n")) {
				const source = line.length === 0 ? " " : line;
				out.push(...wrapTextWithAnsi(this.theme.fg("error", source), bodyWidth));
			}
			return indent(out);
		}
		const out: string[] = [];
		for (const line of this.answer.split("\n")) {
			const source = line.length === 0 ? " " : line;
			out.push(...wrapTextWithAnsi(source, bodyWidth));
		}
		return indent(out);
	}
}

function showBtwOverlay(params: ShowBtwOverlayParams): ShowBtwOverlayResult {
	let resolveReady!: (controller: BtwOverlayController) => void;
	const controllerReady = new Promise<BtwOverlayController>((resolve) => {
		resolveReady = resolve;
	});

	const overlayPromise = params.ctx.ui.custom<void>(
		(tui, theme, _keybindings, done) => {
			const controller = new BtwOverlayController(
				params.question,
				theme,
				tui,
				done,
				params.controller,
				params.commandLabel,
			);
			resolveReady(controller);
			return controller;
		},
		{ overlay: true, overlayOptions: BTW_OVERLAY_OPTIONS },
	);

	return { overlayPromise, controllerReady };
}

export default function (pi: ExtensionAPI): void {
	registerBtwCommand(pi);
	registerBtwShortcut(pi);
}
