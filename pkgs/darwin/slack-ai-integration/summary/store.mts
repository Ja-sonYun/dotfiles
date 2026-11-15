import { createHash, randomUUID } from "node:crypto";
import {
  mkdir,
  readdir,
  readFile,
  rename,
  rm,
  writeFile,
} from "node:fs/promises";
import path from "node:path";

import { isThread, isCard, hasErrorCode } from "./contracts.mjs";
import type { ThreadIdentity, SummaryCard, StoredCard } from "./contracts.mjs";

export function threadKey(thread: ThreadIdentity): string {
  if (!isThread(thread)) throw new Error("The thread identity is unavailable.");
  return createHash("sha256")
    .update(JSON.stringify([thread.teamId, thread.channelId, thread.threadTs]))
    .digest("hex");
}

export class SummaryStore {
  private readonly directory: string;
  private readonly unsaved = new Map<
    string,
    { key: string; card: SummaryCard }
  >();
  private readonly writing = new Set<string>();
  private readonly deleted = new Set<string>();

  constructor(directory: string) {
    this.directory = path.join(directory, "summaries");
  }

  async list(thread: ThreadIdentity): Promise<StoredCard[]> {
    const key = threadKey(thread);
    const directory = path.join(this.directory, key);
    let names: string[];
    try {
      names = await readdir(directory);
    } catch (error) {
      if (!hasErrorCode(error, "ENOENT")) throw error;
      names = [];
    }
    const cards = new Map<string, StoredCard>();
    for (const name of names.filter((name) => name.endsWith(".json"))) {
      let card: unknown;
      try {
        card = JSON.parse(await readFile(path.join(directory, name), "utf8"));
      } catch (error) {
        if (hasErrorCode(error, "ENOENT")) continue;
        throw error;
      }
      if (!isCard(card) || name !== `${card.id}.json`) {
        throw new Error(
          "A saved summary could not be read. Its file has been preserved.",
        );
      }
      if (this.deleted.has(`${key}/${card.id}`)) continue;
      cards.set(card.id, { ...card, saved: true });
    }
    for (const { key: pendingKey, card } of this.unsaved.values()) {
      if (pendingKey === key && !cards.has(card.id)) {
        cards.set(card.id, { ...card, saved: false });
      }
    }
    return [...cards.values()];
  }

  async save(thread: ThreadIdentity, card: SummaryCard): Promise<void> {
    if (!isCard(card)) throw new Error("The summary could not be saved.");
    const key = threadKey(thread);
    const operation = `${key}/${card.id}`;
    if (this.deleted.has(operation))
      throw new Error("This summary was deleted.");
    if (this.writing.has(operation))
      throw new Error("This summary is being saved. Retry shortly.");
    this.writing.add(operation);
    this.unsaved.set(card.id, { key, card });
    const directory = path.join(this.directory, key);
    const temporary = path.join(directory, `.${randomUUID()}.tmp`);
    try {
      await mkdir(directory, { recursive: true, mode: 0o700 });
      // One atomically replaced file per card preserves concurrent summaries.
      await writeFile(temporary, `${JSON.stringify(card)}\n`, {
        mode: 0o600,
        flag: "wx",
      });
      await rename(temporary, path.join(directory, `${card.id}.json`));
      this.unsaved.delete(card.id);
    } finally {
      try {
        await rm(temporary, { force: true });
      } finally {
        this.writing.delete(operation);
      }
    }
  }

  async delete(thread: ThreadIdentity, id: string): Promise<void> {
    const key = threadKey(thread);
    if (typeof id !== "string" || !/^[a-f0-9-]{36}$/.test(id)) {
      throw new Error("Invalid summary ID.");
    }
    const operation = `${key}/${id}`;
    if (this.writing.has(operation))
      throw new Error("This summary is being saved. Retry shortly.");
    this.writing.add(operation);
    try {
      await rm(path.join(this.directory, key, `${id}.json`), { force: true });
      this.deleted.add(operation);
      if (this.unsaved.get(id)?.key === key) this.unsaved.delete(id);
    } finally {
      this.writing.delete(operation);
    }
  }

  pending(thread: ThreadIdentity, id: string): SummaryCard {
    const entry = this.unsaved.get(id);
    if (!entry || entry.key !== threadKey(thread)) {
      throw new Error(
        "The unsaved summary is no longer available in this session.",
      );
    }
    return entry.card;
  }
}
