import { parentPort, workerData } from "node:worker_threads";
import { mask } from "./mask.ts";

try {
  parentPort!.postMessage({
    output: mask(Buffer.from(workerData.input), workerData.env),
  });
} catch {
  parentPort!.postMessage({ failed: true });
}
