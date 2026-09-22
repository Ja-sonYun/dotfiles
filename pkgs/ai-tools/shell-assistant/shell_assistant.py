import asyncio
import os
import sys

import openai
from pydantic import BaseModel


class CommandResponse(BaseModel):
    command: str


async def request(
    input_text: str,
    prompt: str,
) -> CommandResponse | None:
    domain = os.environ.get("LLM_DOMAIN", "").rstrip("/")
    client = openai.AsyncClient(
        base_url=domain if domain.endswith("/v1") else f"{domain}/v1",
        api_key=os.environ.get("CAPI_KEY"),
    )
    response = await client.beta.chat.completions.parse(
        model="gpt-5.3-codex-spark",
        reasoning_effort="low",
        messages=[
            {"role": "system", "content": prompt},
            {"role": "user", "content": input_text},
        ],
        response_format=CommandResponse,
    )
    return response.choices[0].message.parsed


def generate_command() -> None:
    input_text = " ".join(sys.argv[1:]).strip()
    if not input_text:
        print("No instruction provided to generate a command.", file=sys.stderr)
        sys.exit(1)

    event = asyncio.run(
        request(
            input_text,
            "You generate a single safe UNIX shell command from natural language. "
            "Do not include explanations or fences. Avoid destructive commands unless explicitly requested.",
        )
    )
    if event is None or not event.command.strip():
        print("Failed to generate a shell command.", file=sys.stderr)
        sys.exit(1)
    print(event.command.strip())


def fix_grammar() -> None:
    event = asyncio.run(
        request(
            " ".join(sys.argv[1:]),
            "You are an assistant that fixes grammar in shell commands. "
            "If the input is not a command, respond with an error message. "
            "If you can make it better, do so.",
        )
    )
    if event is None:
        print("The input was not recognized as a valid shell command.", file=sys.stderr)
        sys.exit(1)
    print(event.command.strip())
