export type { TaskEntry, TaskView, TaskStatus } from "./contracts.mjs";

interface QueueEntry {
  signal: AbortSignal;
  run(): Promise<void>;
  cancel(): void;
}

export class TaskQueue {
  private running = 0;
  private readonly pending: QueueEntry[] = [];

  constructor(private readonly limit: number) {
    if (!Number.isSafeInteger(limit) || limit < 1)
      throw new Error("The task concurrency limit must be a positive integer.");
  }

  run<T>(signal: AbortSignal, action: () => Promise<T>): Promise<T> {
    signal.throwIfAborted();
    return new Promise<T>((resolve, reject) => {
      const entry: QueueEntry = {
        signal,
        cancel: () => {
          const index = this.pending.indexOf(entry);
          if (index < 0) return;
          this.pending.splice(index, 1);
          signal.removeEventListener("abort", entry.cancel);
          reject(signal.reason);
        },
        run: async () => {
          signal.removeEventListener("abort", entry.cancel);
          try {
            signal.throwIfAborted();
            resolve(await action());
          } catch (error) {
            reject(error);
          }
        },
      };
      this.pending.push(entry);
      signal.addEventListener("abort", entry.cancel, { once: true });
      this.drain();
    });
  }

  private drain(): void {
    while (this.running < this.limit && this.pending.length) {
      const entry = this.pending.shift();
      if (!entry) return;
      this.running++;
      void entry.run().finally(() => {
        this.running--;
        this.drain();
      });
    }
  }
}
