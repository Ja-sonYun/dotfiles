import asyncio
import os
import sys

import openai
from pydantic import BaseModel

api_key = os.environ.get("CAPI_KEY")

all_args = sys.argv[1:]
input_text = " ".join(all_args).strip()


class CommandResponse(BaseModel):
    command: str


async def generate() -> str:
    if not input_text:
        print("No instruction provided to generate a command.", file=sys.stderr)
        sys.exit(1)

    client = openai.AsyncClient(
        base_url="https://lmp.test0.zip/v1",
        api_key=api_key,
    )
    response = await client.beta.chat.completions.parse(
        model="gpt-5.3-codex-spark",
        reasoning_effort="low",
        messages=[
            {
                "role": "system",
                "content": (
                    "You generate a single safe UNIX shell command from natural language. "
                    "Do not include explanations or fences. Avoid destructive commands unless explicitly requested."
                ),
            },
            {"role": "user", "content": input_text},
        ],
        response_format=CommandResponse,
    )

    event = response.choices[0].message.parsed
    if event is None or not event.command.strip():
        print("Failed to generate a shell command.", file=sys.stderr)
        sys.exit(1)

    return event.command.strip()


if __name__ == "__main__":
    print(asyncio.run(generate()))
