type ThreadIdentity = import("./contracts.mjs").ThreadIdentity;
type ThreadMessage = import("./contracts.mjs").ThreadMessage;
type ThreadLocation = import("./contracts.mjs").ThreadLocation;
type StoredCard = import("./contracts.mjs").StoredCard;
type SummaryResult = import("./contracts.mjs").SummaryResult;
type SummaryRequest = import("./contracts.mjs").SummaryRequest;
type SummaryJob = import("./contracts.mjs").SummaryJob;

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

interface SummaryInstance {
  props: SlackProps & ThreadIdentity;
}
interface SummaryPanel {
  host: HTMLElement;
  open(): void;
  progress(text: string): void;
  fail(error: string): void;
  receive(result: SummaryResult): void;
  historyError(error: string): void;
  placementError(error: string): void;
  remove(): void;
}
interface SummaryTask {
  id: string;
  controller: AbortController;
  thread: ThreadIdentity;
  state:
    | { phase: "loading" | "summarizing"; progress: string }
    | { phase: "failed"; error: string };
}
interface SummaryRecord {
  instance: SummaryInstance;
  element: HTMLElement;
  anchor: Element;
  thread: ThreadIdentity;
  identity: string;
  task: SummaryTask | undefined;
  ui: SummaryPanel | undefined;
}
interface StorageRequest {
  record: SummaryRecord;
  resolve(result: SummaryResult): void;
  reject(reason: unknown): void;
  timeout: ReturnType<typeof setTimeout>;
}
type ResizeRow = (ts: string, height: number) => unknown;
interface RowBinding {
  row: HTMLElement;
  message: HTMLElement;
  resize: ResizeRow;
  ts: string;
}
interface Placement {
  row: HTMLElement;
  binding: RowBinding;
  host: HTMLElement;
  signature: string;
  height: string;
  priority: string;
  frame: number;
  observer: ResizeObserver;
}
interface Timeline {
  merge(
    thread: ThreadIdentity,
    cards: StoredCard[],
    deletedIds?: string[],
  ): void;
  scan(records: Iterable<SummaryRecord>): void;
  stop(): void;
}
interface TimelineOptions {
  ancestors(element: Element): Record<string, unknown>[];
  fiberProps(
    fiber: Record<string, unknown>,
  ): Record<string, unknown> | undefined;
  keyFor(thread: ThreadIdentity): string;
  retrySave(thread: ThreadIdentity, cardId: string): Promise<void>;
  deleteCard(thread: ThreadIdentity, cardId: string): Promise<void>;
  memberName(record: SummaryRecord, id: string | undefined): string | undefined;
}
type TimelineFactory = (options: TimelineOptions) => Timeline;
interface Window {
  __slackThreadSummaryBridge(payload: string): void;
  __slackThreadSummary?: {
    owner: string;
    pulse(id: string): boolean;
    receive(id: string, result: SummaryResult): void;
    receiveCards(
      thread: ThreadIdentity,
      cards: StoredCard[],
      deletedIds?: string[],
    ): void;
    stop(): void;
  };
}
