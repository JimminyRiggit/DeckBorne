#!/usr/bin/env python3
"""Add a non-Steam game to Steam by editing the binary shortcuts.vdf.

Registers a launcher tile that boots the given executable with the given
launch options (here: the shadPS4 AppImage + game path). Idempotent: updating
an existing entry with the same AppName instead of duplicating it. Optionally
installs custom artwork (grid/hero/logo/icon) into the Steam grid folder.

Usage:
    add_shortcut.py --name NAME --exe PATH --start-dir DIR \
                    [--launch-options STR] [--icon PATH] [--artwork-dir DIR]

Steam must be restarted to pick up changes. Run from Desktop Mode.
"""
import argparse
import glob
import os
import shutil
import struct
import sys
import time
import zlib

# --- binary VDF (shortcuts.vdf) minimal reader/writer -----------------------
# Types: 0x00 nested map, 0x01 string, 0x02 int32, 0x08 end-of-map.

def _read_cstr(buf, i):
    end = buf.index(b"\x00", i)
    return buf[i:end].decode("utf-8", "replace"), end + 1


def parse(buf):
    """Parse to nested dict. Returns ({}, ...) tolerant of empty/missing file."""
    i = 0

    def parse_map(i):
        out = {}
        while i < len(buf):
            t = buf[i]; i += 1
            if t == 0x08:
                return out, i
            key, i = _read_cstr(buf, i)
            if t == 0x00:
                val, i = parse_map(i)
            elif t == 0x01:
                val, i = _read_cstr(buf, i)
            elif t == 0x02:
                val = struct.unpack("<i", buf[i:i + 4])[0]; i += 4
            else:
                raise ValueError(f"unknown vdf type {t:#x} at {i}")
            out[key] = val
        return out, i

    if not buf:
        return {"shortcuts": {}}
    root, _ = parse_map(0)
    return root


def dump(root):
    out = bytearray()

    def write_map(d):
        for k, v in d.items():
            if isinstance(v, dict):
                out.append(0x00); out.extend(k.encode()); out.append(0x00)
                write_map(v); out.append(0x08)
            elif isinstance(v, int):
                out.append(0x02); out.extend(k.encode()); out.append(0x00)
                out.extend(struct.pack("<i", v))
            else:
                out.append(0x01); out.extend(k.encode()); out.append(0x00)
                out.extend(str(v).encode()); out.append(0x00)
    write_map(root)
    out.append(0x08)
    return bytes(out)


# --- Steam paths & artwork id ----------------------------------------------

def find_userdata_configs():
    """Yield config/ dirs for each Steam user (handles Flatpak + native)."""
    roots = [
        os.path.expanduser("~/.steam/steam/userdata"),
        os.path.expanduser("~/.local/share/Steam/userdata"),
        os.path.expanduser("~/.var/app/com.valvesoftware.Steam/data/Steam/userdata"),
    ]
    for root in roots:
        for uid in glob.glob(os.path.join(root, "*")):
            if os.path.basename(uid).isdigit():
                cfg = os.path.join(uid, "config")
                os.makedirs(cfg, exist_ok=True)
                yield cfg


def _field(entry, key):
    """Case-insensitive field read.

    shortcuts.vdf is rewritten by Steam whenever it exits, so we can't assume the
    key casing we wrote ('appname', 'Exe') survives — read it the way Steam's own
    KeyValues does, case-insensitively.
    """
    for k, v in entry.items():
        if k.lower() == key.lower():
            return v
    return ""


def grid_appid(exe, appname):
    """Unsigned 32-bit id Steam uses to name a shortcut's custom grid artwork.

    Steam computes this from the *Exe field value including its surrounding
    quotes* concatenated with the app name — so we MUST hash the quoted form,
    exactly as it's stored in the 'Exe' field, or the art won't match what Steam
    looks for. (Hashing the unquoted path is the classic non-Steam-art bug.)
    """
    return zlib.crc32((f'"{exe}"' + appname).encode()) | 0x80000000


def signed32(u):
    """VDF stores appid as a signed int32; convert the unsigned grid id to it."""
    return u - 0x100000000 if u >= 0x80000000 else u


def unsigned32(s):
    """Inverse of signed32: read an appid back out of the VDF as unsigned."""
    return s + 0x100000000 if s < 0 else s


def shortcut_entry(name, exe, start_dir, launch_options, icon, last_play_time=None):
    # Stamp LastPlayTime with "now" so the tile shows in Recent Games right after
    # install (0 = never played = hidden from Recent until first launch).
    if last_play_time is None:
        last_play_time = int(time.time())
    # Set appid explicitly so artwork lookups are deterministic (Steam honors it),
    # instead of relying on Steam's internal id computation.
    appid = signed32(grid_appid(exe, name))
    return {
        "appid": appid,
        "appname": name,
        "Exe": f'"{exe}"',
        "StartDir": f'"{start_dir}"',
        "icon": icon or "",
        "ShortcutPath": "",
        "LaunchOptions": launch_options,
        "IsHidden": 0,
        "AllowDesktopConfig": 1,
        "AllowOverlay": 1,
        "OpenVR": 0,
        "Devkit": 0,
        "DevkitGameID": "",
        "DevkitOverrideAppID": 0,
        "LastPlayTime": last_play_time,
        "FlatpakAppID": "",
        "tags": {},
    }


# Canonical source filename (in payloads/artwork/) -> Steam grid destination stem.
#   capsule -> library grid tile (portrait)      <appid>p
#   wide    -> Recent Games / Big Picture / list  <appid>
#   hero    -> banner at top of the game page      <appid>_hero
#   logo    -> transparent logo overlay            <appid>_logo
#   icon    -> small list icon                     <appid>_icon
ARTWORK_SLOTS = [
    ("capsule", "{appid}p"),
    ("wide",    "{appid}"),
    ("hero",    "{appid}_hero"),
    ("logo",    "{appid}_logo"),
    ("icon",    "{appid}_icon"),
]
ART_EXTS = (".ico", ".png", ".jpg", ".jpeg")


def _find_art(artwork_dir, canon):
    for ext in ART_EXTS:
        p = os.path.join(artwork_dir, canon + ext)
        if os.path.exists(p):
            return p
    return None


def install_artwork(config_dir, appid, artwork_dir):
    grid = os.path.join(config_dir, "grid")
    os.makedirs(grid, exist_ok=True)
    installed = 0
    for canon, stem in ARTWORK_SLOTS:
        src = _find_art(artwork_dir, canon)
        if src:
            ext = os.path.splitext(src)[1]
            shutil.copy(src, os.path.join(grid, stem.format(appid=appid) + ext))
            installed += 1
    return installed


def icon_path_for(config_dir, appid, artwork_dir):
    """If an icon.* exists in the artwork dir, return its installed grid path."""
    src = _find_art(artwork_dir, "icon") if artwork_dir else None
    if not src:
        return ""
    return os.path.join(config_dir, "grid", f"{appid}_icon" + os.path.splitext(src)[1])


def remove_artwork(config_dir, appid):
    grid = os.path.join(config_dir, "grid")
    removed = 0
    for f in glob.glob(os.path.join(grid, f"{appid}*")):
        try:
            os.remove(f); removed += 1
        except OSError:
            pass
    return removed


# --- localconfig.vdf: stray play-record cleanup -----------------------------
# Steam records a non-Steam game in localconfig.vdf under Software/Valve/Steam/
# apps, keyed by BOTH representations of the appid (verified against a real Deck):
#     "3941800555" { "BadgeData" "02000000080f" }      <- unsigned id
#     "-353166741" { "Playtime2wks" "1" "Playtime" "1" } <- signed id
# Removing a tile never touched these, so every uninstall — and every change to
# the appid formula — stranded another pair for good. Uninstall now sweeps them.
#
# NB: Steam only reads/writes this file at startup/exit, so it must be stopped
# first (the uninstaller's steam_stop guarantees that), or Steam will overwrite
# our edit from memory when it quits.
#
# This file holds most of the user's Steam settings — including live auth
# tickets — so we never parse-and-redump it. We find the exact byte span of the
# entries to delete and splice them out; every other byte is passed through
# untouched.
LOCALCONFIG_APPS = ["UserLocalConfigStore", "Software", "Valve", "Steam", "apps"]


def _skip_ws(text, i, end):
    while i < end:
        if text[i] in " \t\r\n":
            i += 1
        elif text.startswith("//", i):
            nl = text.find("\n", i)
            i = end if nl < 0 else nl + 1
        else:
            break
    return i


def _read_quoted(text, i, end):
    """i points at the opening quote; returns (value, index past closing quote).

    Escapes are consumed as pairs, so a value containing \\" or braces (Steam
    stores JSON blobs this way) can't fool the brace matcher below.
    """
    i += 1
    out = []
    while i < end:
        c = text[i]
        if c == "\\" and i + 1 < end:
            out.append(text[i:i + 2]); i += 2; continue
        if c == '"':
            return "".join(out), i + 1
        out.append(c); i += 1
    raise ValueError("unterminated string")


def _block_end(text, i, end):
    """i points at '{'; returns index just past the matching '}' (quote-aware)."""
    depth = 0
    while i < end:
        c = text[i]
        if c == '"':
            _, i = _read_quoted(text, i, end); continue
        if text.startswith("//", i):
            nl = text.find("\n", i); i = end if nl < 0 else nl + 1; continue
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    raise ValueError("unbalanced braces")


def _children(text, start, end):
    """Yield the direct children of a block body as descriptor dicts."""
    i = start
    while True:
        i = _skip_ws(text, i, end)
        if i >= end or text[i] == "}":
            return
        if text[i] != '"':
            raise ValueError(f"unexpected {text[i]!r} at offset {i}")
        key, after_key = _read_quoted(text, i, end)
        j = _skip_ws(text, after_key, end)
        if j < end and text[j] == "{":
            b_end = _block_end(text, j, end)
            yield {"key": key, "block": True, "key_start": i,
                   "body_start": j + 1, "body_end": b_end - 1, "end": b_end}
            i = b_end
        else:
            val, after_val = _read_quoted(text, j, end)
            yield {"key": key, "block": False, "key_start": i, "val": val,
                   "val_start": j, "val_end": after_val, "end": after_val}
            i = after_val


def _find_child(text, start, end, name):
    for ch in _children(text, start, end):
        if ch["key"].lower() == name.lower():   # Steam's KeyValues are case-insensitive
            return ch
    return None


def _find_path(text, path):
    """Walk nested block names from the file root; returns the descriptor or None."""
    start, end, node = 0, len(text), None
    for name in path:
        node = _find_child(text, start, end, name)
        if not node or not node["block"]:
            return None
        start, end = node["body_start"], node["body_end"]
    return node


def purge_play_records(config_dir, appid, dry_run=False):
    """Delete <appid>'s entries (both signed and unsigned) from localconfig.vdf.

    Returns a human-readable status string; never raises — cleanup must never be
    the reason an uninstall fails.
    """
    path = os.path.join(config_dir, "localconfig.vdf")
    if not os.path.exists(path):
        return "no localconfig.vdf — nothing to purge"
    try:
        with open(path, encoding="utf-8", errors="surrogateescape") as f:
            text = orig = f.read()

        if _find_path(text, LOCALCONFIG_APPS) is None:
            return "could not locate Software/Valve/Steam/apps — left untouched"

        removed = []
        # Both keys Steam uses for one non-Steam game. Re-find the block each
        # pass: splicing the first entry shifts every offset after it.
        for key in (str(appid), str(signed32(appid))):
            apps = _find_path(text, LOCALCONFIG_APPS)
            ch = _find_child(text, apps["body_start"], apps["body_end"], key)
            if not ch or not ch["block"]:
                continue
            keys = ", ".join(c["key"] for c in
                             _children(text, ch["body_start"], ch["body_end"]))
            start = text.rfind("\n", 0, ch["key_start"]) + 1   # take the whole line
            end = ch["end"]
            if end < len(text) and text[end] == "\n":
                end += 1                                        # and its newline
            text = text[:start] + text[end:]
            removed.append(f"{key} ({keys or 'empty'})")

        if not removed:
            return f"no play records for appid {appid} — nothing to purge"
        if dry_run:
            return "would purge " + "; ".join(removed)

        # Re-parse before committing: if our splice broke the structure, bail out
        # rather than hand Steam a corrupt settings file.
        if _find_path(text, LOCALCONFIG_APPS) is None:
            return "purge aborted — result failed validation, file left untouched"

        shutil.copy(path, path + ".deckborne.bak")
        tmp = path + ".deckborne.tmp"
        with open(tmp, "w", encoding="utf-8", errors="surrogateescape") as f:
            f.write(text)
        os.replace(tmp, path)          # atomic — never leave a half-written config
        return (f"purged {len(removed)} play record(s): " + "; ".join(removed) +
                f"  ({len(orig) - len(text)} bytes)")
    except Exception as e:             # noqa: BLE001 — never fail an uninstall over cleanup
        return f"skipped — {type(e).__name__}: {e}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--name", default="")         # required for add; optional with --by-exe
    ap.add_argument("--exe", default="")          # required for add; used for grid appid
    ap.add_argument("--start-dir", default="")
    ap.add_argument("--launch-options", default="")
    ap.add_argument("--icon", default="")
    ap.add_argument("--artwork-dir", default="")
    ap.add_argument("--remove", action="store_true",
                    help="delete the shortcut (and its artwork) instead of adding it")
    ap.add_argument("--by-exe", action="store_true",
                    help="on --remove, match EVERY shortcut pointing at --exe "
                         "regardless of name (what an uninstall wants: it catches "
                         "tiles added under a throwaway STEAM_TILE_NAME too)")
    ap.add_argument("--keep-play-records", action="store_true",
                    help="on --remove, leave Steam's playtime/badge entries in "
                         "localconfig.vdf instead of purging them")
    ap.add_argument("--dry-run", action="store_true",
                    help="report what --remove would do, change nothing")
    args = ap.parse_args()

    if not args.remove and not (args.exe and args.start_dir):
        print("--exe and --start-dir are required when adding a shortcut", file=sys.stderr)
        return 2
    if not args.remove and not args.name:
        print("--name is required when adding a shortcut", file=sys.stderr)
        return 2
    if args.remove and not (args.name or args.by_exe):
        print("--remove needs --name, or --by-exe to match every tile for --exe",
              file=sys.stderr)
        return 2
    if args.by_exe and not args.exe:
        print("--by-exe requires --exe", file=sys.stderr)
        return 2

    configs = list(find_userdata_configs())
    if not configs:
        print("No Steam userdata found — is Steam installed and has it run once?", file=sys.stderr)
        return 0 if args.remove else 1  # nothing to remove is success

    appid = grid_appid(args.exe, args.name) if args.exe else None
    for cfg in configs:
        vdf = os.path.join(cfg, "shortcuts.vdf")
        buf = open(vdf, "rb").read() if os.path.exists(vdf) else b""
        root = parse(buf)
        shortcuts = root.setdefault("shortcuts", {})

        if args.remove:
            # An uninstall must leave nothing behind, so match on Exe rather than
            # name: every tile DeckBorne creates points at our shadPS4 AppImage,
            # whatever it's called. That catches tiles added under a throwaway
            # STEAM_TILE_NAME, which name-matching silently stranded forever.
            # --name still narrows it to a single tile when that's what you want.
            #
            # Read fields case-insensitively and compare paths normalised: this
            # file is REWRITTEN BY STEAM on exit, so by the time an uninstall
            # reads it the keys and quoting are Steam's, not the ones we wrote.
            # --by-exe also falls back to matching --name, so a tile is never
            # stranded just because Steam stored Exe in a shape we didn't expect.
            def _norm_exe(s):
                return os.path.normpath(str(s).strip().strip('"')) if s else ""

            def _ours(v):
                if not isinstance(v, dict):
                    return False
                if not args.by_exe:
                    return _field(v, "appname") == args.name
                if args.exe and _norm_exe(_field(v, "Exe")) == _norm_exe(args.exe):
                    return True
                return bool(args.name) and _field(v, "appname") == args.name

            doomed = [v for v in shortcuts.values() if _ours(v)]
            kept = [v for v in shortcuts.values() if not _ours(v)]

            # Each tile's own appid is what its artwork and play records are
            # filed under — trust the stored value over recomputing, so tiles
            # written by an older appid formula still clean up correctly.
            def _appid_of(v):
                a = _field(v, "appid")
                if isinstance(a, int):
                    return unsigned32(a)
                return grid_appid(_norm_exe(_field(v, "Exe")), _field(v, "appname"))

            if args.dry_run:
                for v in doomed:
                    a = _appid_of(v)
                    art = len(glob.glob(os.path.join(cfg, "grid", f"{a}*")))
                    print(f"would remove '{v.get('appname')}' (appid {a}) + {art} artwork file(s)")
                    if not args.keep_play_records:
                        print(f"    {purge_play_records(cfg, a, dry_run=True)}")
                if not doomed:
                    print(f"no matching shortcuts -> {vdf}")
                continue

            root["shortcuts"] = {str(i): v for i, v in enumerate(kept)}
            if os.path.exists(vdf):
                shutil.copy(vdf, vdf + ".deckborne.bak")
                with open(vdf, "wb") as f:
                    f.write(dump(root))
            for v in doomed:
                a = _appid_of(v)
                art = remove_artwork(cfg, a)
                print(f"removed '{v.get('appname')}' (appid {a}) + {art} artwork file(s) -> {vdf}")
                # Sweep Steam's own record too — otherwise every removed tile
                # leaves a permanent pair of entries in localconfig.vdf.
                if not args.keep_play_records:
                    print(f"    {purge_play_records(cfg, a)}")
            if not doomed:
                print(f"no matching shortcuts -> {vdf}")
            continue

        # --- add / update ---
        idx = None
        for k, v in shortcuts.items():
            if isinstance(v, dict) and v.get("appname") == args.name:
                idx = k; break
        if idx is None:
            idx = str(len(shortcuts))
        else:
            # Reinstalling over an entry whose appid we'd now compute differently
            # (e.g. the grid_appid formula changed between builds) would leave the
            # old <appid>*.png files orphaned in grid/ forever — uninstall only
            # globs the *current* appid. Sweep them here so a reinstall self-heals.
            prev = shortcuts[idx].get("appid")
            if isinstance(prev, int) and unsigned32(prev) != appid:
                stale = remove_artwork(cfg, unsigned32(prev))
                if stale:
                    print(f"  cleaned {stale} stale artwork file(s) from appid {unsigned32(prev)}")

        # Point the shortcut's icon at the installed icon art if one is supplied.
        icon = args.icon or icon_path_for(cfg, appid, args.artwork_dir)
        if not icon and idx in shortcuts and isinstance(shortcuts[idx], dict):
            icon = shortcuts[idx].get("icon", "") or ""
        shortcuts[idx] = shortcut_entry(
            args.name, args.exe, args.start_dir, args.launch_options, icon)

        if os.path.exists(vdf):
            shutil.copy(vdf, vdf + ".deckborne.bak")
        with open(vdf, "wb") as f:
            f.write(dump(root))
        print(f"wrote shortcut '{args.name}' -> {vdf}  (appid {appid}, shows in Recent)")

        if args.artwork_dir and os.path.isdir(args.artwork_dir):
            n = install_artwork(cfg, appid, args.artwork_dir)
            print(f"  installed {n} artwork asset(s)")

    print("Done. Restart Steam to apply.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
