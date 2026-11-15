import { randomUUID } from "node:crypto";
import { mkdir, readFile, rename, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import { hasErrorCode, isStoredReviewSnapshot } from "./review/contracts.mjs";
import type { StoredReviewSnapshot } from "./review/contracts.mjs";

export class TaskStore {
  private writing: Promise<void> = Promise.resolve();

  constructor(private readonly directory: string) {}

  async load(): Promise<StoredReviewSnapshot[]> {
    let value: unknown;
    try {
      value = JSON.parse(
        await readFile(path.join(this.directory, "reviews.json"), "utf8"),
      );
    } catch (error) {
      if (hasErrorCode(error, "ENOENT")) return [];
      throw error;
    }
    if (!Array.isArray(value) || !value.every(isStoredReviewSnapshot))
      throw new Error(
        "Saved reviews could not be read. Their file has been preserved.",
      );
    return value;
  }

  save(snapshots: StoredReviewSnapshot[]): Promise<void> {
    const contents = `${JSON.stringify(snapshots)}\n`;
    const write = async () => {
      await mkdir(this.directory, { recursive: true, mode: 0o700 });
      const temporary = path.join(this.directory, `.${randomUUID()}.tmp`);
      try {
        await writeFile(temporary, contents, { mode: 0o600, flag: "wx" });
        await rename(temporary, path.join(this.directory, "reviews.json"));
      } finally {
        await rm(temporary, { force: true });
      }
    };
    this.writing = this.writing.catch(() => {}).then(write);
    return this.writing;
  }

  async flush(): Promise<void> {
    await this.writing;
  }
}
