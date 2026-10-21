import sys
from pathlib import Path

from pydantic import ValidationError
from pydantic_settings import (
    BaseSettings,
    CliApp,
    PydanticBaseSettingsSource,
    SettingsConfigDict,
    SettingsError,
)

from tmux_mcp.config import Config
from tmux_mcp.server import create_server


class Cli(BaseSettings):
    model_config = SettingsConfigDict(
        cli_enforce_required=True,
        cli_exit_on_error=False,
        cli_prog_name="tmux-mcp",
        hide_input_in_errors=True,
    )
    config: Path

    @classmethod
    def settings_customise_sources(
        cls,
        settings_cls: type[BaseSettings],
        init_settings: PydanticBaseSettingsSource,
        env_settings: PydanticBaseSettingsSource,
        dotenv_settings: PydanticBaseSettingsSource,
        file_secret_settings: PydanticBaseSettingsSource,
    ) -> tuple[PydanticBaseSettingsSource, ...]:
        return (init_settings,)

    def cli_cmd(self) -> None:
        config = Config.model_validate_json(self.config.read_bytes())
        create_server(config).run(transport="stdio")


def main() -> int:
    try:
        CliApp.run(Cli)
    except (OSError, ValidationError, SettingsError):
        print(
            "tmux-mcp: cannot load configuration; use --help for usage.",
            file=sys.stderr,
        )
        return 2
    return 0
