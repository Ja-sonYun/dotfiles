import asyncio
import json
import sys
from typing import Any, Self


class Response:
    def __init__(self, value: object) -> None:
        if not isinstance(value, dict) or not isinstance(value.get("text"), str):
            raise TypeError("Invalid evaluation response.")
        self.text: str = value["text"]
        self.status = value.get("status")

    def raise_for_status(self) -> None:
        if not isinstance(self.status, int) or not 200 <= self.status < 300:
            raise RuntimeError("Evaluation request failed.")

    def json(self) -> Any:
        return json.loads(self.text)


class Transport:
    def __init__(self) -> None:
        self.pending: dict[int, asyncio.Future[object]] = {}
        self.next_id = 0
        self.reader: asyncio.Task[None] | None = None
        self.input = asyncio.StreamReader(limit=1024 * 1024)
        self.pipe: asyncio.ReadTransport | None = None

    def emit(self, value: dict[str, object]) -> None:
        data = json.dumps(value, ensure_ascii=False) + "\n"
        if len(data.encode("utf-8")) > 1024 * 1024:
            raise ValueError("Rule transport frame exceeds 1 MiB.")
        sys.stdout.write(data)
        sys.stdout.flush()

    async def read(self) -> None:
        try:
            while line := await self.input.readline():
                if len(line) > 1024 * 1024 or not line.endswith(b"\n"):
                    raise TypeError("Invalid rule response frame.")
                value = json.loads(line)
                if not isinstance(value, dict) or not isinstance(value.get("id"), int):
                    raise TypeError("Invalid rule response frame.")
                future = self.pending.get(value["id"])
                if future is None or future.done():
                    continue
                if value.get("error") == "timeout":
                    future.set_exception(
                        TimeoutError("Evaluation transport timed out.")
                    )
                elif value.get("error"):
                    future.set_exception(RuntimeError("Evaluation transport failed."))
                else:
                    future.set_result(value.get("value"))
        finally:
            for future in self.pending.values():
                if not future.done():
                    future.set_exception(RuntimeError("Evaluation transport closed."))

    async def exchange(self, kind: str, value: object, timeout: float) -> object:
        self.next_id += 1
        identifier = self.next_id
        future = asyncio.get_running_loop().create_future()
        self.pending[identifier] = future
        self.emit({"type": kind, "id": identifier, "value": value, "timeout": timeout})
        try:
            return await asyncio.wait_for(future, timeout)
        finally:
            self.pending.pop(identifier, None)
            if future.cancelled():
                self.emit({"type": "cancel", "id": identifier})

    async def redact(self, request: str, timeout: float) -> str:
        result = await self.exchange("redact", request, timeout)
        if not isinstance(result, str):
            raise TypeError("Invalid redacted request.")
        return result

    async def post(
        self,
        url: str,
        *,
        json: dict[str, object],
        headers: dict[str, str],
        timeout: float,
    ) -> Response:
        result = await self.exchange(
            "http",
            {
                "url": url,
                "json": json,
                "headers": headers,
            },
            timeout,
        )
        return Response(result)

    async def __aenter__(self) -> Self:
        self.pipe, _ = await asyncio.get_running_loop().connect_read_pipe(
            lambda: asyncio.StreamReaderProtocol(self.input), sys.stdin.buffer
        )
        self.reader = asyncio.create_task(self.read())
        return self

    async def __aexit__(self, *_error: object) -> None:
        if self.reader is not None:
            self.reader.cancel()
            try:
                await self.reader
            except asyncio.CancelledError:
                pass
        if self.pipe is not None:
            self.pipe.close()
