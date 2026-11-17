type StoredReviewSnapshot = import("./contracts.mjs").StoredReviewSnapshot;
type ProtectedElement = import("./contracts.mjs").ProtectedElement;
type ReviewContext = import("./contracts.mjs").ReviewContext;
type ReviewRequest = import("./contracts.mjs").ReviewRequest;
type ReviewMessage = import("./contracts.mjs").ReviewMessage;
type ReviewResult = import("./contracts.mjs").ReviewResult;
type ClassificationResult = import("./contracts.mjs").ClassificationResult;
type ReviewToolEvent = import("../contracts.mjs").ToolEvent;

interface DeltaAttributes {
  [key: string]: unknown;
  link?: string | undefined;
  indent?: number | undefined;
  list?: string | undefined;
}
type DeltaInsert = string | Record<string, unknown>;
interface InsertOp {
  insert: DeltaInsert;
  attributes?: DeltaAttributes;
}
interface DeltaUnit {
  insert: DeltaInsert;
  attributes: DeltaAttributes;
}
interface DeltaChange {
  insert?: DeltaInsert;
  retain?: number;
  delete?: number;
  attributes?: DeltaAttributes;
}
interface DraftElement extends ProtectedElement {
  units: DeltaUnit[];
}
interface DraftProjection {
  source: DeltaUnit[];
  elements: DraftElement[];
  text: string;
  lines: DeltaAttributes[];
}
interface DraftPatch {
  contents: DeltaChange[];
  expected: DeltaUnit[];
  text: string;
  lines: DeltaAttributes[];
}
type ConvertList = (html: string) => { ops: InsertOp[] };
interface DraftTools {
  capture(ops: InsertOp[]): DraftProjection;
  parts(text: string): string[];
  valid(elements: ProtectedElement[], text: unknown): text is string;
  serialize(text: string, lines: DeltaAttributes[]): string;
  editLines(
    before: string,
    after: string,
    lines: DeltaAttributes[],
    selection?: { start: number; end: number },
  ): DeltaAttributes[];
  patch(
    draft: DraftProjection,
    text: string,
    convert: ConvertList,
    lines?: DeltaAttributes[],
  ): DraftPatch;
  matches(ops: InsertOp[], expected: DeltaUnit[]): boolean;
}
interface EditorInput {
  getContents(): unknown;
  updateContents?: (value: { contents: DeltaChange[] }) => unknown;
  convertSlackHTMLToDelta?: (html: string) => unknown;
  instance?: { quill?: Record<string, unknown> | undefined } | undefined;
  quill?: Record<string, unknown> | undefined;
}
interface SlackMessage {
  ts: string;
  thread_ts?: string | undefined;
  channel?: string | undefined;
  text?: string | undefined;
  user?: string | undefined;
  username?: string | undefined;
  bot_profile?: { name?: string | undefined } | undefined;
  reply_count?: number | undefined;
  latest_reply?: string | undefined;
}
interface HistoryArgs {
  channelId: string;
  threadTs: string;
  latest?: string | null | undefined;
  limit: number;
  skipSubscriptionUpdate: boolean;
}
type LoadHistory = (args: HistoryArgs) => unknown;
interface ThreadSource {
  channelId: string;
  threadTs: string;
  timestamps: string[];
  messages: Record<string, SlackMessage | undefined>;
  rootMsg: SlackMessage | undefined;
  reachedStart?: boolean | undefined;
  load?: LoadHistory | undefined;
}
interface SlackProps {
  [key: string]: unknown;
  teamId?: string | null | undefined;
  channelId?: string | null | undefined;
  threadTs?: string | null | undefined;
  channelDisplayName?: string | null | undefined;
  channel?: { name?: string | null | undefined } | null | undefined;
  draft?: Record<string, unknown> | null | undefined;
  isComposerPage?: boolean | undefined;
}
interface ComposerProps extends SlackProps {
  sendMessage: (...args: unknown[]) => unknown;
}
interface MessageInput {
  props: ComposerProps;
  getInputRef(): unknown;
}
interface ComposerParent {
  props: SlackProps;
  state?: Record<string, unknown> | undefined;
}
interface ComposerRecord {
  instance: MessageInput;
  parent: ComposerParent | undefined;
  element: HTMLElement;
  descriptor: PropertyDescriptor;
  raw: ComposerProps;
  proxy: ComposerProps | undefined;
}
type ReviewPhase =
  "loading" | "checking" | "classification-error" | "confirm" | "review";
interface ReviewPanel {
  conflict(text: string, useCurrent: () => void): void;
  refresh(): void;
  setStage(stage: "loading" | "checking" | "review"): void;
  classificationFailed(error: string): void;
  sendFailed(message: string): void;
  confirm(): void;
  receive(result: ReviewResult): void;
  close(): void;
}
interface PendingReview {
  receivedReviewTurn?: number;
  receivedClassificationTurn?: number;
  approved?: string;
  sendUnknown?: boolean;
  stale?: boolean;
  indicator?: HTMLElement;
  destination: ConversationDestination;
  sending?: boolean;
  sendError?: string;
  tools?: ReviewToolEvent[];
  startedAt: number;
  workspaceId: string;
  deferredReview?: boolean;
  dismissed?: boolean;
  result?: ReviewResult;
  classification?: ClassificationResult;
  location: string;
  id: string;
  record: ComposerRecord;
  args: unknown[];
  fingerprint: string;
  original: string;
  reviewOriginal: string;
  previewOriginal: string;
  elements: DraftElement[];
  projection: DraftProjection;
  turn: number;
  phase: ReviewPhase;
  initialStage: "checking" | "review";
  busy: boolean;
  applyFailed: boolean;
  context: ReviewContext | undefined;
  ui: ReviewPanel | undefined;
}
interface Window {
  __slackAiTasks?: {
    open(taskId?: string): void;
    close(): void;
    isOpen(): boolean;
  };
  __slackReviewBridge(payload: string): void;
  __slackMessageReview?: {
    receiveSnapshots(snapshots: StoredReviewSnapshot[]): void;
    receiveSaved(id: string, turn: number, error?: string): void;
    owner: string;
    pulse(id: string): boolean;
    receive(id: string, turn: number, result: ReviewResult): boolean;
    receiveClassification(
      id: string,
      turn: number,
      result: ClassificationResult,
    ): boolean;
    stop(): void;
    open(id: string): Promise<void>;
    close(): void;
    has(id: string): boolean;
    activity(id: string, tools: ReviewToolEvent[]): void;
    cancel(id: string): void;
  };
}
interface ShadowRoot {
  getSelection?(): Selection | null;
}

type ReviewDecision =
  | { action: "cancel" }
  | { action: "original"; text: string }
  | { action: "revised"; text: string; patch: DraftPatch };

interface ReviewPanelDependencies {
  draftTools: DraftTools;
  validSuggestion(current: PendingReview, text: unknown): text is string;
  readableSuggestion(current: PendingReview, text: string): string;
  suggestionParts(text: string): string[];
  preparePatch(
    current: PendingReview,
    text: string,
    lines?: DeltaAttributes[],
  ): DraftPatch;
  notify(message: ReviewMessage): void;
  beginStage(
    current: PendingReview,
    stage: "checking" | "review",
  ): Promise<void>;
  cancel(): void;
  resolve(id: string, decision: ReviewDecision): string;
  dismiss(): void;
  isSelected(current: PendingReview): boolean;
  disableSend: boolean;
}
type ReviewPanelFactory = (
  current: PendingReview,
  dependencies: ReviewPanelDependencies,
) => ReviewPanel;
