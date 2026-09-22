import fcntl
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import TypedDict
from urllib.parse import unquote, urlsplit


class FolderItem(TypedDict):
    name: str
    path: str


class HiddenItem(TypedDict):
    name: str
    uri: str


class MonthlyFolders(TypedDict):
    path: str
    after: str


class Settings(TypedDict):
    enable: bool
    items: list[FolderItem]
    hiddenItems: list[HiddenItem]
    monthlyFolders: MonthlyFolders | None
    mysides: str
    stateDirectory: str


def local_path(uri: str) -> Path | None:
    parsed = urlsplit(uri)
    if parsed.scheme == "file" and parsed.netloc in ("", "localhost"):
        return Path(unquote(parsed.path))
    return None


def read_sidebar(command: str) -> dict[str, list[str]]:
    result = subprocess.run(
        [command, "list"], check=True, capture_output=True, text=True
    )
    items: dict[str, list[str]] = {}
    for line in result.stdout.splitlines():
        name, separator, uri = line.partition(" -> ")
        if not separator:
            raise ValueError(f"Unexpected mysides output: {line!r}")
        items.setdefault(name, []).append(uri)
    return items


def remove_item(command: str, items: dict[str, list[str]], name: str, uri: str) -> None:
    existing = items.get(name, [])
    for candidate in existing:
        if candidate != uri and (
            local_path(uri) is None or local_path(candidate) != local_path(uri)
        ):
            raise ValueError(f"Sidebar name belongs to a different URI: {name!r}")

    for _ in existing:
        subprocess.run([command, "remove", name], check=True)
    items.pop(name, None)


def add_item(command: str, items: dict[str, list[str]], name: str, uri: str) -> None:
    remove_item(command, items, name, uri)
    subprocess.run([command, "add", name, uri], check=True)
    items[name] = [uri]


def update_sidebar(settings: Settings) -> None:
    if not settings["enable"]:
        # Home Manager may leave a locally modified or untracked agent loaded.
        loaded = subprocess.run(
            ["/bin/launchctl", "print", f"gui/{os.getuid()}/com.user.finder-sidebar"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        if loaded.returncode == 0:
            raise RuntimeError("Finder sidebar agent is still loaded; refusing cleanup")

    items = read_sidebar(settings["mysides"])
    monthly = settings["monthlyFolders"]
    month_paths: list[Path] = []
    if settings["enable"] and monthly is not None:
        root = Path(monthly["path"])
        # Do not recreate an unavailable volume or iCloud root.
        ancestors = [
            Path(item["path"])
            for item in settings["items"]
            if root.is_relative_to(item["path"])
        ]
        available_root = (
            max(ancestors, key=lambda path: len(path.parts))
            if ancestors
            else root.parent
        )
        if available_root.is_dir():
            first = datetime.now(timezone.utc).astimezone().date().replace(day=1)
            month_paths = [
                root / day.strftime("%Y.%m")
                for day in (first, first - timedelta(days=1))
            ]

    if monthly is not None and (not settings["enable"] or month_paths):
        root = Path(monthly["path"])
        for name, uris in list(items.items()):
            for uri in uris:
                path = local_path(uri)
                if (
                    path is not None
                    and path.parent == root
                    and re.fullmatch(r"[0-9]{4}\.(0[1-9]|1[0-2])", path.name)
                    and path not in month_paths
                ):
                    remove_item(settings["mysides"], items, name, uri)
                    break

    for item in settings["hiddenItems"]:
        if settings["enable"]:
            remove_item(settings["mysides"], items, item["name"], item["uri"])
        else:
            add_item(settings["mysides"], items, item["name"], item["uri"])

    if not settings["enable"]:
        return

    for folder in settings["items"]:
        path = Path(folder["path"])
        if path.is_dir():
            add_item(settings["mysides"], items, folder["name"], path.as_uri())
        if monthly is not None and folder["name"] == monthly["after"]:
            for path in month_paths:
                path.mkdir(parents=True, exist_ok=True)
                add_item(settings["mysides"], items, path.name, path.as_uri())


def main() -> int:
    try:
        # The configuration is generated from typed Nix options in the store.
        settings: Settings = json.loads(Path(sys.argv[1]).read_text())
        state_directory = Path(settings["stateDirectory"])
        state_directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        with (state_directory / "lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            update_sidebar(settings)
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"finder-sidebar: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
