import re
import string
from typing import Annotated, Self

from pydantic import (
    AfterValidator,
    BaseModel,
    ConfigDict,
    Field,
    model_validator,
)

KEYS = {
    "Enter": "Enter",
    "Tab": "Tab",
    "Escape": "Escape",
    "Backspace": "BSpace",
    "Delete": "DC",
    "Up": "Up",
    "Down": "Down",
    "Left": "Left",
    "Right": "Right",
    "Home": "Home",
    "End": "End",
    "PageUp": "PPage",
    "PageDown": "NPage",
    **{f"F{number}": f"F{number}" for number in range(1, 13)},
    **{
        f"C-{letter}": f"C-{letter}"
        for letter in string.ascii_lowercase
        if letter != "q"
    },
}


def session_pattern(value: str) -> str:
    try:
        re.compile(value)
    except re.error:
        raise ValueError("Invalid session pattern.") from None
    return value


def allowed_key(value: str) -> str:
    if value not in KEYS:
        raise ValueError("Unsupported or prohibited key.")
    return value


class ConfigModel(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True, hide_input_in_errors=True)


class CaptureConfig(ConfigModel):
    defaultLines: Annotated[int, Field(gt=0)] = 200
    maxLines: Annotated[int, Field(gt=0)] = 5000
    maxOutputBytes: Annotated[int, Field(gt=0)] = 65536

    @model_validator(mode="after")
    def check_lines(self) -> Self:
        if self.defaultLines > self.maxLines:
            raise ValueError("defaultLines must not exceed maxLines.")
        return self


class SendKeysConfig(ConfigModel):
    enable: bool = False
    allowedKeys: list[Annotated[str, AfterValidator(allowed_key)]] = Field(
        default_factory=lambda: list(KEYS),
    )


class RedactionConfig(ConfigModel):
    timeoutSeconds: Annotated[int, Field(gt=0)] = 10
    maxInputBytes: Annotated[int, Field(gt=0)] = 16777216


class Config(ConfigModel):
    allowedSessionPatterns: list[Annotated[str, AfterValidator(session_pattern)]] = (
        Field(
            default_factory=list,
        )
    )
    capture: CaptureConfig = Field(default_factory=CaptureConfig)
    sendKeys: SendKeysConfig = Field(default_factory=SendKeysConfig)
    redaction: RedactionConfig = Field(default_factory=RedactionConfig)
    instructions: str = ""
