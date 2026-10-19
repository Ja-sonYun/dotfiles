import { redact } from "../../redaction/index.ts";

export async function exchange(
  frame: any,
  signal: AbortSignal,
): Promise<unknown> {
  if (frame.type === "redact") {
    if (
      typeof frame.value !== "string" ||
      Buffer.byteLength(frame.value) > 64 * 1024
    ) {
      throw new Error("Invalid evaluation payload");
    }
    return (await redact(Buffer.from(frame.value), signal)).toString("utf8");
  }
  const request = frame.value;
  if (
    request?.url !== "https://api.typesafe.ai/v1/systemone" ||
    !request.json ||
    typeof request.json !== "object" ||
    typeof request.headers?.Authorization !== "string"
  )
    throw new Error("Invalid evaluation request");
  const body = JSON.stringify(request.json);
  if (Buffer.byteLength(body) > 64 * 1024)
    throw new Error("Evaluation payload exceeded");
  const response = await fetch(request.url, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: request.headers.Authorization,
    },
    body,
    redirect: "error",
    signal,
  });
  const chunks: Uint8Array[] = [];
  let size = 0;
  if (response.body) {
    for await (const chunk of response.body) {
      size += chunk.length;
      if (size > 512 * 1024) {
        throw new Error("Evaluation response exceeded");
      }
      chunks.push(chunk);
    }
  }
  return {
    status: response.status,
    text: Buffer.concat(chunks).toString("utf8"),
  };
}
