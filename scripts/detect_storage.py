#!/usr/bin/env python3
"""Enumerate the storage devices DeckBorne can install the extracted game onto.

Single source of truth for "where can the ~30GB go?", used by BOTH sides:
  * ui/backend.py   — subprocesses `--json` to build the install-location picker
  * 00_preflight.sh — `--check <root>` to validate the chosen target before a run
  * install runs    — `--human` for a readable block at the top of the run log

Why a script and not a lib.sh function: the UI needs structured data, the shell
needs an exit code, and duplicating mount parsing in two languages is how the two
drift apart. The UI shells out to THIS file at $DECKBORNE_ROOT/scripts/ — the same
resolution it already uses for install.sh — so detection can be fixed without an
AppImage rebuild (which has to happen on the Deck; see CLAUDE.md).

What counts as a storage device here:
  * the filesystem holding $HOME              -> the internal drive, always offered
  * anything mounted under /run/media, /media -> SteamOS auto-mounts the SD card and
    USB drives there (`/run/media/mmcblk0p1`, `/run/media/deck/<label>`)

Only GAMES_DIR moves. The emulator (APP_DIR) deliberately stays in $HOME — see
config/deckborne.env for why (the Steam tile's Exe feeds the grid appid).

Filesystem rule: only POSIX filesystems are offered. The game is plain data, but
exFAT/NTFS are case-insensitive, and both the game's asset lookups and stage 40's
"does this path already exist?" mod resolver answer differently there.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path

REQUIRED_BYTES = int(os.environ.get("DECKBORNE_REQUIRED_BYTES", 36 * 1000**3))

POSIX_FS = {
    "ext2", "ext3", "ext4", "btrfs", "xfs", "f2fs", "jfs", "reiserfs",
    "zfs", "overlay", "bcachefs", "nilfs2",
}
NON_POSIX_FS = {
    "exfat", "vfat", "msdos", "fat", "ntfs", "ntfs3", "fuseblk",
    "iso9660", "udf", "squashfs", "hfsplus",
}
PSEUDO_FS = {
    "proc", "sysfs", "devtmpfs", "devpts", "tmpfs", "ramfs", "cgroup", "cgroup2",
    "securityfs", "debugfs", "tracefs", "pstore", "bpf", "configfs", "efivarfs",
    "mqueue", "hugetlbfs", "autofs", "fusectl", "binfmt_misc", "nsfs", "rpc_pipefs",
    "fuse.portal", "fuse.gvfsd-fuse", "erofs",
}

GAMES_SUBPATH = "Games/shadps4"

STORAGE_STATE = Path(
    os.environ.get("DECKBORNE_STORAGE_FILE")
    or Path.home() / ".local" / "share" / "DeckBorne" / "storage_root"
)


def _unoct(s: str) -> str:
    """Undo mountinfo's octal escaping of space/tab/newline/backslash."""
    for esc, ch in (("\\040", " "), ("\\011", "\t"), ("\\012", "\n"), ("\\134", "\\")):
        s = s.replace(esc, ch)
    return s


def _mounts() -> list[dict]:
    """Parse /proc/self/mountinfo into mountpoint / fstype / source / options.

    mountinfo rather than /proc/mounts: its lone " - " separator makes fstype and
    source unambiguous even when a mountpoint contains spaces.
    """
    out = []
    try:
        text = Path("/proc/self/mountinfo").read_text()
    except OSError:
        return out
    for line in text.splitlines():
        if " - " not in line:
            continue
        left, right = line.split(" - ", 1)
        lf, rf = left.split(), right.split()
        if len(lf) < 6 or len(rf) < 2:
            continue
        out.append({
            "mountpoint": _unoct(lf[4]),
            "options": lf[5],
            "fstype": rf[0],
            "source": _unoct(rf[1]),
        })
    return out


def _labels() -> dict[str, str]:
    """Map resolved device path -> filesystem label, via /dev/disk/by-label."""
    out: dict[str, str] = {}
    try:
        entries = list(Path("/dev/disk/by-label").iterdir())
    except OSError:
        return out
    for link in entries:
        try:
            out[str(link.resolve())] = link.name.replace("\\x20", " ")
        except OSError:
            pass
    return out


_UUID_RE = re.compile(
    r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", re.I)


def _mountpoint_label(mountpoint: str) -> str:
    """The mountpoint's basename, when it is a name a human would recognise.

    SteamOS mounts a labelled volume at /run/media/<user>/<label>, so the basename is
    usually the right display name. An UNLABELLED card is mounted at its UUID instead —
    verified on-device 2026-07-24, which showed up as "SD card (90f57fcc-c7de-...)".
    Returning "" there lets the caller fall back to a bare "SD card".
    """
    name = Path(mountpoint).name
    return "" if _UUID_RE.match(name) else name


def _is_removable(source: str) -> bool:
    """Read /sys/block/<disk>/removable — an SD card or USB stick reads 1."""
    name = Path(source).name
    if not name:
        return False
    for cand in (name, name.rstrip("0123456789"), name.split("p")[0]):
        try:
            return (Path("/sys/block") / cand / "removable").read_text().strip() == "1"
        except OSError:
            continue
    return False


def _owning_mount(path: Path, mounts: list[dict]) -> dict | None:
    """The mount whose mountpoint is the longest prefix of `path`."""
    best = None
    try:
        resolved = path.resolve()
    except OSError:
        resolved = path
    for m in mounts:
        mp = m["mountpoint"]
        if resolved == Path(mp) or str(resolved).startswith(mp.rstrip("/") + "/"):
            if best is None or len(mp) > len(best["mountpoint"]):
                best = m
    return best


def _installed_game(root: Path) -> str | None:
    """Title-id of a game already extracted under this root, or None.

    Keys on eboot.bin, not the directory, so a half-extracted or already-uninstalled
    tree does not read as "installed here".
    """
    try:
        for child in sorted((root / GAMES_SUBPATH).iterdir()):
            if child.is_dir() and not child.name.endswith("-UPDATE") \
                    and (child / "eboot.bin").is_file():
                return child.name
    except OSError:
        pass
    return None


def _writable(root: Path) -> bool:
    """Probe writability by actually creating and removing a directory.

    os.access() lies on a read-only mount, on a full disk, and under mount options
    that override the permission bits — all live possibilities for a removable card.
    """
    probe = root / ".deckborne-write-probe"
    try:
        probe.mkdir(exist_ok=True)
        probe.rmdir()
        return True
    except OSError:
        return False


def _entry(root: Path, mount: dict, kind: str, name: str,
           deckborne_root: Path | None) -> dict:
    fstype = mount["fstype"]
    try:
        st = os.statvfs(root)
        free = st.f_bavail * st.f_frsize
        total = st.f_blocks * st.f_frsize
    except OSError:
        free = total = 0

    ro = "ro" in mount["options"].split(",")
    writable = (not ro) and root.is_dir() and _writable(root)
    fs_ok = fstype in POSIX_FS
    installed = _installed_game(root)
    enough = free >= REQUIRED_BYTES or installed is not None

    notes = []
    if ro:
        notes.append("mounted read-only")
    elif not writable:
        notes.append("not writable")
    if fstype in NON_POSIX_FS:
        notes.append(
            f"{fstype} can't safely hold the game — it is case-insensitive, which "
            "breaks asset lookups and mod placement. Format the card as ext4 "
            "(Steam Deck: Settings → System → Format SD Card)."
        )
    elif not fs_ok:
        notes.append(f"unrecognised filesystem '{fstype}' — not offered")
    if not enough:
        notes.append(f"needs ~{REQUIRED_BYTES / 1000**3:.0f} GB free, "
                     f"has {free / 1000**3:.1f} GB")

    is_medium = False
    if deckborne_root is not None and mount["mountpoint"] != "/":
        is_medium = str(deckborne_root).startswith(mount["mountpoint"].rstrip("/") + "/")

    return {
        "root": str(root),
        "name": name,
        "kind": kind,
        "mountpoint": mount["mountpoint"],
        "device": mount["source"],
        "fstype": fstype,
        "total_bytes": total,
        "free_bytes": free,
        "writable": writable,
        "fs_ok": fs_ok,
        "enough_space": enough,
        "usable": bool(writable and fs_ok),
        "installed": installed,
        "is_installer_medium": is_medium,
        "games_dir": str(root / GAMES_SUBPATH),
        "note": " · ".join(notes),
    }


def detect() -> list[dict]:
    """Every candidate install root, internal first, then SD cards, then the rest.

    The internal entry's root is $HOME (not the mountpoint), so the default layout is
    byte-identical to every install predating this feature.
    """
    mounts = _mounts()
    labels = _labels()
    home = Path(os.environ.get("HOME") or Path.home())
    dbroot = os.environ.get("DECKBORNE_ROOT")
    deckborne_root = Path(dbroot).resolve() if dbroot else None

    entries: list[dict] = []
    seen: set[str] = set()

    hm = _owning_mount(home, mounts)
    if hm is not None:
        entries.append(_entry(home, hm, "internal", "Internal storage", deckborne_root))
        seen.add(hm["mountpoint"])

    for m in mounts:
        mp = m["mountpoint"]
        if mp in seen or m["fstype"] in PSEUDO_FS:
            continue
        if not any(mp.startswith(p) and mp != p.rstrip("/")
                   for p in ("/run/media/", "/media/", "/mnt/")):
            continue
        if not m["source"].startswith("/dev/"):
            continue
        seen.add(mp)

        label = labels.get(m["source"]) or _mountpoint_label(mp)
        dev = Path(m["source"]).name
        if dev.startswith("mmcblk"):
            kind, base = "sdcard", "SD card"
        elif _is_removable(m["source"]):
            kind, base = "removable", "USB drive"
        else:
            kind, base = "removable", "External drive"
        name = f"{base} ({label})" if label else base
        entries.append(_entry(Path(mp), m, kind, name, deckborne_root))

    order = {"internal": 0, "sdcard": 1, "removable": 2}
    entries.sort(key=lambda e: (order.get(e["kind"], 3), e["name"]))
    return entries


def find_installs(title_id: str) -> list[str]:
    """Roots that already hold an extracted copy of `title_id`, best candidate first.

    Searches every detected device plus the remembered root and $HOME, so a copy left on
    a device that is no longer the chosen target is still found. Keys on the base
    eboot.bin: a bare directory or a half-extracted tree is not an install.
    """
    roots = [e["root"] for e in detect()]
    try:
        remembered = STORAGE_STATE.read_text().strip()
    except OSError:
        remembered = ""
    if remembered:
        roots.insert(0, remembered)
    roots.append(str(Path(os.environ.get("HOME") or Path.home())))

    found, seen = [], set()
    for r in roots:
        if not r or r in seen:
            continue
        seen.add(r)
        if (Path(r) / GAMES_SUBPATH / title_id / "eboot.bin").is_file():
            found.append(r)
    return found


def _gb(n: int) -> str:
    return f"{n / 1000**3:.1f} GB"


def human(entries: list[dict]) -> str:
    lines = []
    for e in entries:
        extra = []
        if e["installed"]:
            extra.append(f"game already installed ({e['installed']})")
        if e["is_installer_medium"]:
            extra.append("DeckBorne installer medium")
        if not e["enough_space"]:
            extra.append("insufficient space")
        lines.append(
            f"  {e['name']}  [{'usable' if e['usable'] else 'UNUSABLE'}]\n"
            f"      path   : {e['root']}\n"
            f"      device : {e['device']} ({e['fstype']})\n"
            f"      space  : {_gb(e['free_bytes'])} free of {_gb(e['total_bytes'])}"
            + (f"\n      note   : {e['note']}" if e["note"] else "")
            + (f"\n      also   : {', '.join(extra)}" if extra else "")
        )
    return "\n".join(lines) if lines else "  (no storage devices detected)"


def check(root: str) -> int:
    """Validate one chosen root: 0 if it can hold the install, 1 otherwise.

    The failure reason goes to stderr as a single user-facing line — stage 00 passes
    it straight to die()/ui_error, so it reaches the UI panel verbatim. Insufficient
    space is a WARN on stdout, not a failure: that call belongs to the caller.
    """
    path = Path(root)
    mounts = _mounts()
    m = _owning_mount(path, mounts)
    unplugged = (f"install location '{root}' is unavailable — if this is an SD card or "
                 f"USB drive, is it still plugged in?")
    if m is None or not path.is_dir():
        print(unplugged, file=sys.stderr)
        return 1

    e = _entry(path, m, "chosen", root, None)
    if not e["usable"]:
        print(f"install location '{root}' can't be used: {e['note']}", file=sys.stderr)
        return 1
    if not e["enough_space"]:
        print(f"WARN {e['note']}")
    print(f"OK {e['fstype']} {e['free_bytes']} {e['device']}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="DeckBorne storage detection")
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--json", action="store_true", help="machine-readable device list")
    g.add_argument("--human", action="store_true", help="readable list for the run log")
    g.add_argument("--check", metavar="ROOT", help="validate one install root")
    g.add_argument("--find-install", metavar="TITLE_ID",
                   help="print roots already holding this title, one per line")
    args = ap.parse_args()

    if args.check:
        return check(args.check)
    if args.find_install:
        for r in find_installs(args.find_install):
            print(r)
        return 0
    entries = detect()
    if args.json:
        json.dump({"required_bytes": REQUIRED_BYTES, "devices": entries},
                  sys.stdout, indent=2)
        sys.stdout.write("\n")
    else:
        print(human(entries))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
