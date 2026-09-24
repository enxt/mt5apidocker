#!/usr/bin/env python3
"""Settle the terminal's configuration before it starts. Runs on every boot.

Three files, all read by the terminal at start-up and nowhere else:

* ``startup.ini`` is passed as ``terminal64.exe /config:...``. It is
  MetaQuotes' own mechanism for logging in at launch: account, password and
  server, plus the Experts switches, so algo trading comes up enabled and is
  not switched off by the account change. This replaces typing the
  credentials into the GUI over VNC.

* ``Config/servers.dat`` is the list of broker servers the terminal knows.
  The image is built from MetaQuotes' generic installer, which knows only
  MetaQuotes' servers, and with an unknown ``Server=`` the terminal does not
  even attempt the login - it logs nothing at all. The broker's list is
  therefore supplied at runtime, like the credentials: a ``servers.dat``
  placed in the mounted ``/config`` folder is copied in on every start.

* ``Config/common.ini`` is the terminal's persistent settings. Algo trading
  and the chart bar limit are re-asserted here as well, because the terminal
  rewrites this file from memory on exit and may have saved ``Enabled=0``.

Max bars in chart caps how much history the terminal keeps per chart, and so
the most ``copy_rates_*`` can return. At the installed default of 100,000 the
hourly FX series stopped at exactly 99,999 bars.
"""

import os
import re
import shutil
from pathlib import Path

MT5_DIR = Path(os.environ.get("MT5_DIR", "/opt/wineprefix/drive_c/Metatrader-5"))
STARTUP = MT5_DIR / "startup.ini"
COMMON = MT5_DIR / "Config" / "common.ini"
IMPORT_DIR = Path(os.environ.get("MT5_IMPORT_DIR", "/config"))


def env(name: str, default: str = "") -> str:
    # Strip quotes a .env file or a compose default may have carried through.
    return os.environ.get(name, default).strip().strip("'\"")


def max_bars() -> str:
    value = env("MT5_MAX_BARS", "1000000")
    if value.isdigit() and int(value) > 0:
        return value
    print(f"==> MT5_MAX_BARS={value!r} is not a positive integer; using 1000000")
    return "1000000"


def write_startup(bars: str) -> None:
    login, password, server = env("MT5_LOGIN", "0"), env("MT5_PASSWORD"), env("MT5_SERVER")
    lines = ["[Common]"]
    if login.isdigit() and int(login) > 0 and server:
        lines += [f"Login={login}", f"Password={password}", f"Server={server}", "KeepPrivate=1"]
        print(f"==> terminal will log in to {login} on {server}")
    else:
        print("==> MT5_LOGIN/MT5_SERVER not set; the terminal starts without logging in")
    lines += [
        "NewsEnable=0",
        "[Charts]",
        f"MaxBars={bars}",
        "[Experts]",
        "Enabled=1",
        "AllowLiveTrading=1",
        "AllowDllImport=0",
        "Account=0",
        "Profile=0",
    ]
    STARTUP.write_text("\r\n".join(lines) + "\r\n", encoding="ascii", errors="replace")
    STARTUP.chmod(0o600)


def import_servers() -> None:
    source = IMPORT_DIR / "servers.dat"
    if source.is_file():
        (MT5_DIR / "Config").mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, MT5_DIR / "Config" / "servers.dat")
        print(f"==> servers.dat imported from {source} ({source.stat().st_size} bytes)")
    elif env("MT5_SERVER") and not env("MT5_SERVER").startswith("MetaQuotes"):
        # The one hint there will be: the terminal itself says nothing.
        print(
            f"==> WARNING: no {source}. The terminal only knows MetaQuotes' servers, "
            f"so it will not try to log in to {env('MT5_SERVER')}. See the README."
        )


def settle_common(bars: str) -> None:
    if not COMMON.exists():
        return
    raw = COMMON.read_bytes()
    try:
        text = raw.decode("utf-16")
    except UnicodeDecodeError:
        # Leaving it alone beats corrupting the only copy of the settings.
        print("==> common.ini is not UTF-16; left untouched")
        return
    before = text

    text = re.sub(r"^Enabled=0\s*$", "Enabled=1", text, count=1, flags=re.MULTILINE)
    found = re.search(r"^MaxBars=(\d+)\s*$", text, re.MULTILINE)
    if found:
        text = text[: found.start()] + f"MaxBars={bars}" + text[found.end():]
    elif "[Charts]" in text:
        text = text.replace("[Charts]", f"[Charts]\r\nMaxBars={bars}", 1)
    else:
        if not text.endswith(("\n", "\r")):
            text += "\r\n"
        text += f"[Charts]\r\nMaxBars={bars}\r\n"

    if text != before:
        COMMON.write_bytes(text.encode("utf-16"))  # utf-16 writes the BOM
        print(f"==> common.ini settled (algo trading on, MaxBars={bars})")


if __name__ == "__main__":
    bars = max_bars()
    import_servers()
    write_startup(bars)
    settle_common(bars)
