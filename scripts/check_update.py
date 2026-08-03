#!/usr/bin/env python3
"""Ask GitHub whether a newer DeckBorne release exists. Read-only — downloads nothing.

    check_update.py --json      {"current","latest","update_available","url","error"}
    check_update.py --human     one line for a run log

Always exits 0 and always prints a complete payload; a failure is reported in
"error" rather than as a crash, so a caller never has to parse stderr.

Every run appends one line to logs/update-check.log, so a click in the UI leaves
evidence on the stick. DECKBORNE_UPDATE_NOLOG=1 suppresses that.

Overrides for testing: DECKBORNE_UPDATE_URL, DECKBORNE_UPDATE_CURRENT.
"""
from __future__ import annotations

import datetime
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path

TIMEOUT = 10
API = "https://api.github.com/repos/{repo}/releases/latest"


def _repo_root() -> str:
    return os.environ.get("DECKBORNE_ROOT") or str(Path(__file__).resolve().parent.parent)


def _from_env() -> tuple[str, str]:
    script = ('source "$0/scripts/lib.sh" >/dev/null 2>&1 || exit 1; '
              'load_env >/dev/null 2>&1 || exit 1; '
              'printf "%s\\n%s\\n" "$DECKBORNE_VERSION" "$DECKBORNE_REPO"')
    try:
        res = subprocess.run(["bash", "-c", script, _repo_root()],
                             capture_output=True, text=True, timeout=20)
    except (OSError, subprocess.SubprocessError):
        return "", ""
    if res.returncode != 0:
        return "", ""
    out = res.stdout.splitlines()
    return (out[0].strip() if out else ""), (out[1].strip() if len(out) > 1 else "")


def parse_version(s: str) -> tuple[int, ...] | None:
    m = re.match(r"\s*v?\.?\s*(\d+(?:\.\d+)*)", str(s or ""))
    if not m:
        return None
    return tuple(int(p) for p in m.group(1).split("."))


def newer(latest: str, current: str) -> bool:
    a, b = parse_version(latest), parse_version(current)
    if a is None or b is None:
        return False
    n = max(len(a), len(b))
    return a + (0,) * (n - len(a)) > b + (0,) * (n - len(b))


def fetch_latest(repo: str) -> tuple[str, str, str]:
    url = os.environ.get("DECKBORNE_UPDATE_URL") or API.format(repo=repo)
    req = urllib.request.Request(url, headers={
        "Accept": "application/vnd.github+json",
        "User-Agent": "DeckBorne-update-check",
    })
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            data = json.loads(r.read().decode("utf-8", "replace"))
    except urllib.error.HTTPError as e:
        if e.code == 403:
            return "", "", "Rate limited"
        if e.code == 404:
            return "", "", "No releases found"
        return "", "", f"GitHub error {e.code}"
    except urllib.error.URLError:
        return "", "", "No internet"
    except (TimeoutError, OSError):
        return "", "", "GitHub timed out"
    except ValueError:
        return "", "", "Bad response"
    if not isinstance(data, dict):
        return "", "", "Bad response"
    tag = str(data.get("tag_name") or "").strip()
    if not tag:
        return "", "", "Release has no tag"
    return tag, str(data.get("html_url") or "").strip(), ""


def check() -> dict:
    current, repo = _from_env()
    current = os.environ.get("DECKBORNE_UPDATE_CURRENT") or current
    out = {"current": current, "latest": "", "update_available": False,
           "url": "", "error": ""}
    if not current:
        out["error"] = "Version unknown"
        return out
    if not repo:
        out["error"] = "Repo unknown"
        return out
    tag, url, err = fetch_latest(repo)
    if err:
        out["error"] = err
        return out
    out["latest"] = tag
    out["url"] = url
    if parse_version(tag) is None:
        out["error"] = f"Bad tag '{tag}'"
        return out
    out["update_available"] = newer(tag, current)
    return out


def log_result(res: dict) -> None:
    if os.environ.get("DECKBORNE_UPDATE_NOLOG") == "1":
        return
    if res.get("error"):
        outcome = f"error={res['error']}"
    elif res.get("update_available"):
        outcome = "update-available"
    else:
        outcome = "up-to-date"
    line = (f"[{datetime.datetime.now():%Y-%m-%d %H:%M:%S}] "
            f"current=v{res.get('current') or '?'} "
            f"latest={res.get('latest') or '-'} {outcome}\n")
    try:
        d = Path(_repo_root()) / "logs"
        d.mkdir(parents=True, exist_ok=True)
        with open(d / "update-check.log", "a", encoding="utf-8") as f:
            f.write(line)
            f.flush()
            os.fsync(f.fileno())
    except OSError:
        pass


def main() -> int:
    res = check()
    log_result(res)
    if "--json" in sys.argv:
        print(json.dumps(res))
        return 0
    if res["error"]:
        print(f"update check: {res['error']}")
    elif res["update_available"]:
        print(f"update check: v{res['current']} installed, {res['latest']} available")
    else:
        print(f"update check: v{res['current']} is the latest release")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
