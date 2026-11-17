from pathlib import Path
from typing import Annotated, Literal, Self

from pydantic import BaseModel, ConfigDict, Field, HttpUrl, model_validator

NonEmptyString = Annotated[str, Field(min_length=1)]


class Configuration(BaseModel):
    model_config = ConfigDict(extra="forbid", hide_input_in_errors=True)


class Listen(Configuration):
    host: NonEmptyString
    port: Annotated[int, Field(strict=True, ge=1, le=65535)]


class GoogleAuth(Configuration):
    type: Literal["google"]
    base_url: HttpUrl
    owner_sub: NonEmptyString
    state_dir: Path
    credentials_file: Path
    client_id_key: NonEmptyString
    client_secret_key: NonEmptyString


class BearerAuth(Configuration):
    type: Literal["bearer"]
    token_file: Path


class Backend(Configuration):
    namespace: NonEmptyString | None = None
    mode: Literal["auto", "legacy"] | None = None


class HttpBackend(Backend):
    transport: Literal["http"]
    url: HttpUrl
    bearer_token_file: Path | None = None
    max_sse_event_size: Annotated[int, Field(strict=True, gt=0)] = 1024 * 1024


class StdioBackend(Backend):
    transport: Literal["stdio"]
    command: NonEmptyString
    args: list[str] = Field(default_factory=list)
    env: dict[str, str] = Field(default_factory=dict)
    env_files: dict[str, Path] = Field(default_factory=dict)

    @model_validator(mode="after")
    def separate_environment_sources(self) -> Self:
        if self.env.keys() & self.env_files.keys():
            raise ValueError("env and env_files must not define the same variable")
        return self


class GatewayConfig(Configuration):
    name: NonEmptyString
    listen: Listen
    list_page_size: Annotated[int, Field(strict=True, gt=0)] = 50
    auth: Annotated[GoogleAuth | BearerAuth, Field(discriminator="type")]
    backends: Annotated[
        list[Annotated[HttpBackend | StdioBackend, Field(discriminator="transport")]],
        Field(min_length=1),
    ]
