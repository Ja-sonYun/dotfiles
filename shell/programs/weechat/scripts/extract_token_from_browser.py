#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import shutil
import sqlite3
import subprocess
import sys
import tempfile
from collections.abc import Iterator
from configparser import ConfigParser
from contextlib import contextmanager
from pathlib import Path
from sqlite3 import OperationalError
from typing import Literal, assert_never


class AESCipher:
    def __init__(self, key: bytes) -> None:
        self.key = key

    def decrypt(self, text: bytes) -> bytes:
        cipher = AES.new(self.key, AES.MODE_CBC, IV=(b" " * 16))
        return unpad(cipher.decrypt(text), AES.block_size)


@contextmanager
def sqlite3_connect(path: Path) -> Iterator[sqlite3.Connection]:
    con = sqlite3.connect(f"file:{path}?immutable=1", uri=True)
    try:
        yield con
    finally:
        con.close()


def get_cookies(
    cookies_path: Path, cookie_query: str, params: tuple[str, ...]
) -> tuple[str | bytes, str | bytes | None]:
    with sqlite3_connect(cookies_path) as con:
        cookie_d_value = con.execute(cookie_query.format("d"), params).fetchone()
        cookie_ds_value = con.execute(cookie_query.format("ds"), params).fetchone()
        if cookie_d_value and cookie_ds_value:
            return cookie_d_value[0], cookie_ds_value[0]
        elif cookie_d_value:
            return cookie_d_value[0], None
        else:
            print(
                f"Couldn't find the 'd' cookie value in {cookies_path}", file=sys.stderr
            )
            sys.exit(1)


parser = argparse.ArgumentParser(
    description="Extract Slack tokens from the browser files"
)
parser.add_argument(
    "browser",
    help="Which browser to extract from",
    metavar="<browser>",
    choices=["firefox", "firefox-snap", "chromium", "chrome", "chrome-beta"],
)
parser.add_argument(
    "--profile", help="Profile to look up cookies for", metavar="<profile>", nargs="?"
)
parser.add_argument(
    "--container",
    help="Firefox container to look up cookies for",
    metavar="<id or name>",
    nargs="?",
)
parser.add_argument(
    "--no-secretstorage",
    help=(
        "Disable accessing freedesktop Secret D-Bus service, "
        "use the default password to decrypt Chrome cookies instead"
    ),
    action="store_true",
)
args = parser.parse_args()

browser: Literal["firefox", "chrome"]

if sys.platform.startswith("linux"):
    chrome_key_iterations = 1
    if args.browser == "firefox-snap":
        browser = "firefox"
        browser_data = Path.home().joinpath("snap/firefox/common/.mozilla/firefox")
    elif args.browser == "firefox":
        browser = "firefox"
        browser_data = Path.home().joinpath(".mozilla/firefox")
    elif args.browser == "chromium":
        browser = "chrome"
        browser_data = Path.home().joinpath(".config/chromium")
    elif args.browser in ["chrome", "chrome-beta"]:
        browser = "chrome"
        browser_data = Path.home().joinpath(".config/google-%s" % args.browser)
    else:
        print(
            f'Unsupported browser "{args.browser}" on platform Linux.', file=sys.stderr
        )
        sys.exit(1)
elif sys.platform.startswith("darwin"):
    chrome_key_iterations = 1003
    if args.browser in ["firefox", "firefox-snap"]:
        browser = "firefox"
        browser_data = Path.home().joinpath("Library/Application Support/Firefox")
    elif args.browser == "chromium":
        browser = "chrome"
        browser_data = Path.home().joinpath("Library/Application Support/Chromium")
    elif args.browser in ["chrome", "chrome-beta"]:
        browser = "chrome"
        chrome_directory = "Chrome Beta" if args.browser == "chrome-beta" else "Chrome"
        browser_data = Path.home().joinpath(
            "Library/Application Support/Google", chrome_directory
        )
    else:
        print(
            f'Unsupported browser "{args.browser}" on platform macOS.', file=sys.stderr
        )
        sys.exit(1)
else:
    print("Currently only Linux and macOS is supported by this script", file=sys.stderr)
    sys.exit(1)

profile = args.profile

if browser == "firefox":
    default_profile_path = None
    if profile is not None:
        rel = browser_data.joinpath(profile)
        for p in [Path(profile), rel, browser_data / "Profiles" / profile]:
            if p.exists():
                default_profile_path = p
                break

        if default_profile_path is None:
            print(f"Path {profile} doesn't exist", file=sys.stderr)
            sys.exit(1)
    else:
        profile_path = browser_data.joinpath("profiles.ini")
        profile_data = ConfigParser()
        profile_data.read(profile_path)

        for key in profile_data.sections():
            if not key.startswith("Install"):
                continue

            value = profile_data[key]
            if "Default" in value:
                default_profile_path = browser_data.joinpath(value["Default"])
                break

        if default_profile_path is None:
            for key in profile_data.sections():
                if not key.startswith("Profile"):
                    continue
                value = profile_data[key]
                if value.get("Default") == "1" and value.get("Path"):
                    profile_path = Path(value["Path"])
                    default_profile_path = (
                        browser_data / profile_path
                        if value.get("IsRelative", "1") == "1"
                        else profile_path
                    )
                    break

        if default_profile_path is None or not default_profile_path.exists():
            print(
                "Default profile detection failed; try specifying --profile",
                file=sys.stderr,
            )
            sys.exit(1)

    cookies_path = default_profile_path.joinpath("cookies.sqlite")

    if args.container:
        try:
            ctx_id = int(args.container)
        except ValueError:
            # non-numeric container ID, try to find by name
            ctx_id = None
            with open(default_profile_path.joinpath("containers.json"), "rb") as fp:
                containers = json.load(fp)
                for i in containers["identities"]:
                    if "name" in i and i["name"] == args.container:
                        ctx_id = i["userContextId"]
                        break
            if ctx_id is None:
                print(
                    f"Couldn't find Firefox container '{args.container}'",
                    file=sys.stderr,
                )
                sys.exit(1)

        userctx = f"^userContextId={ctx_id}"
    else:
        userctx = ""

    cookie_query = (
        "SELECT value FROM moz_cookies WHERE originAttributes = ? "
        "AND host = '.slack.com' AND name = '{}'"
    )
    cookie_d_value, cookie_ds_value = get_cookies(
        cookies_path, cookie_query, (userctx,)
    )

    storage_path = default_profile_path.joinpath(
        f"storage/default/https+++app.slack.com{userctx}/ls/data.sqlite"
    )
    storage_query = "SELECT compression_type, conversion_type, value FROM data WHERE key = 'localConfig_v2'"
    local_config = None

    try:
        with sqlite3_connect(storage_path) as con:
            is_compressed, conversion, payload = con.execute(storage_query).fetchone()

        if is_compressed:
            from snappy import snappy

            payload = snappy.decompress(payload)

        if conversion == 1:
            local_config_str = payload.decode("utf-8")
        else:
            # untested; possibly Windows-only?
            local_config_str = payload.decode("utf-16")

        local_config = json.loads(local_config_str)
    except (OperationalError, TypeError):
        pass

elif browser == "chrome":
    from Crypto.Cipher import AES
    from Crypto.Protocol.KDF import PBKDF2
    from Crypto.Util.Padding import unpad
    from plyvel import DB
    from plyvel._plyvel import IOError as pIOErr

    if not profile:
        profile = "Default"

    default_profile_path = browser_data.joinpath(profile)

    cookies_path = default_profile_path.joinpath("Cookies")
    if not cookies_path.exists():
        cookies_path = default_profile_path.joinpath("Network/Cookies")
    cookie_query = (
        "SELECT encrypted_value FROM cookies WHERE "
        "host_key = '.slack.com' AND name = '{}'"
    )
    cookie_d_value, cookie_ds_value = get_cookies(cookies_path, cookie_query, ())

    storage_name = "Chromium" if args.browser == "chromium" else "Chrome"
    if sys.platform == "darwin":
        try:
            result = subprocess.run(
                [
                    "/usr/bin/security",
                    "find-generic-password",
                    "-s",
                    f"{storage_name} Safe Storage",
                    "-a",
                    storage_name,
                    "-w",
                ],
                check=True,
                capture_output=True,
            )
        except (OSError, subprocess.CalledProcessError):
            print(
                "Could not read the browser password from macOS Keychain.",
                file=sys.stderr,
            )
            sys.exit(1)
        passwd = result.stdout.rstrip(b"\r\n")
    elif args.no_secretstorage:
        passwd = b"peanuts"
    else:
        try:
            import secretstorage
            from secretstorage.exceptions import SecretStorageException
        except ImportError:
            print(
                "Install secretstorage to read the Linux browser password.",
                file=sys.stderr,
            )
            sys.exit(1)

        try:
            bus = secretstorage.dbus_init()
            try:
                collection = secretstorage.get_default_collection(bus)
                for item in collection.get_all_items():
                    if item.get_label() == f"{storage_name} Safe Storage":
                        passwd = item.get_secret()
                        break
                else:
                    raise RuntimeError("Browser password not found.")
            finally:
                bus.close()
        except (SecretStorageException, OSError, RuntimeError):
            print(
                "Could not read the Linux browser password. Use --no-secretstorage "
                "only if the browser uses the default password.",
                file=sys.stderr,
            )
            sys.exit(1)

    salt = b"saltysalt"
    length = 16
    key = PBKDF2(passwd, salt, length, chrome_key_iterations)
    cipher = AESCipher(key)

    with sqlite3_connect(cookies_path) as con:
        version_row = con.execute(
            "SELECT value FROM meta WHERE key = 'version'"
        ).fetchone()
    cookie_version = int(version_row[0]) if version_row else 0

    def decrypt_cookie(value: str | bytes) -> str:
        if not isinstance(value, bytes) or value[:3] not in {b"v10", b"v11"}:
            raise ValueError("Unsupported browser cookie encryption.")
        decrypted = cipher.decrypt(value[3:])
        if cookie_version >= 24:
            decrypted = decrypted[32:]
        return decrypted.decode("utf8")

    try:
        cookie_d_value = decrypt_cookie(cookie_d_value)
        if cookie_ds_value:
            cookie_ds_value = decrypt_cookie(cookie_ds_value)
    except ValueError:
        print(
            "Could not decrypt browser cookies with the stored password.",
            file=sys.stderr,
        )
        sys.exit(1)

    local_storage_path = default_profile_path.joinpath("Local Storage")
    leveldb_path = local_storage_path.joinpath("leveldb")
    leveldb_key = b"_https://app.slack.com\x00\x01localConfig_v2"
    try:
        db = DB(str(leveldb_path))
        try:
            local_storage_value = db.get(leveldb_key)
        finally:
            db.close()
    except pIOErr:
        with tempfile.TemporaryDirectory(
            dir=local_storage_path, prefix="leveldb-", suffix=".tmp"
        ) as tmp_dir:
            shutil.copytree(leveldb_path, tmp_dir, dirs_exist_ok=True)
            db = DB(tmp_dir)
            try:
                local_storage_value = db.get(leveldb_key)
            finally:
                db.close()

    local_config = json.loads(local_storage_value[1:]) if local_storage_value else None

else:
    assert_never(browser)

if cookie_ds_value:
    cookie_value = f"d={cookie_d_value};d-s={cookie_ds_value}"
else:
    cookie_value = cookie_d_value

if local_config:
    teams = [
        team
        for team in local_config["teams"].values()
        if not team["id"].startswith("E")
    ]
else:
    teams = [
        {
            "token": "<token>",
            "name": (
                "Couldn't find any tokens automatically, but you can try to extract "
                "it manually as described in the readme and register the team like this"
            ),
        }
    ]

register_commands = [
    f"{team['name']}:\n/slack register {team['token']}:{cookie_value}" for team in teams
]
print("\n\n".join(register_commands))
