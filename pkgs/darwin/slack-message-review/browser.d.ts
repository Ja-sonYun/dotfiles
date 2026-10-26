type ProtectedElement = import("./contracts.mjs").ProtectedElement;
type ReviewContext = import("./contracts.mjs").ReviewContext;
type ReviewRequest = import("./contracts.mjs").ReviewRequest;
type ReviewResult = import("./contracts.mjs").ReviewResult;
type ClassificationResult = import("./contracts.mjs").ClassificationResult;

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
}
type ConvertList = (html: string) => { ops: InsertOp[] };
interface DraftTools {
  capture(ops: InsertOp[]): DraftProjection;
  parts(text: string): string[];
  valid(elements: ProtectedElement[], text: unknown): text is string;
  patch(
    draft: DraftProjection,
    text: string,
    convert: ConvertList,
  ): { contents: DeltaChange[]; expected: DeltaUnit[] };
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
  refresh(): void;
  setStage(stage: "loading" | "checking" | "review"): void;
  classificationFailed(error: string): void;
  sendFailed(message: string): void;
  confirm(): void;
  receive(result: ReviewResult): void;
  close(): void;
}
interface PendingReview {
  id: string;
  record: ComposerRecord;
  args: unknown[];
  fingerprint: string;
  original: string;
  reviewOriginal: string;
  previewOriginal: string;
  elements: DraftElement[];
  projection: DraftProjection;
  finish(value: unknown): void;
  turn: number;
  phase: ReviewPhase;
  initialStage: "checking" | "review";
  busy: boolean;
  applyFailed: boolean;
  context: ReviewContext | undefined;
  ui: ReviewPanel | undefined;
}
interface Window {
  __slackReviewBridge(payload: string): void;
  __slackMessageReview?: {
    owner: string;
    pulse(id: string): boolean;
    receive(id: string, turn: number, result: ReviewResult): void;
    receiveClassification(
      id: string,
      turn: number,
      result: ClassificationResult,
    ): void;
    stop(): void;
  };
}
interface ShadowRoot {
  getSelection?(): Selection | null;
}
