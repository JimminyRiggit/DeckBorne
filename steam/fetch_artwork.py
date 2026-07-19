#!/usr/bin/env python3
"""Fetch tile art from SteamGridDB into payloads/artwork/ (canonical names).

Two modes:
  • Pick specific assets by their SteamGridDB IDs (from the /hero/<id>, /grid/<id>,
    /logo/<id>, /icon/<id> URLs):
        fetch_artwork.py --hero-id 34872 --grid-id 82619 --logo-id 55377 --icon-id 36789
  • Auto: top-voted static art for a game name:
        fetch_artwork.py --auto --game "Bloodborne"

Saves canonical slot files (capsule/wide/hero/logo/icon). A portrait grid becomes
`capsule`, a landscape grid becomes `wide`. Non-PNG/JPG art (e.g. webp heroes) is
converted to PNG so Steam renders it. Requests send a browser User-Agent — the
SteamGridDB CDN sits behind Cloudflare and 1010-blocks default urllib UAs.

API key: --api-key, $STEAMGRIDDB_API_KEY, or config/steamgriddb.key (gitignored).
"""
import argparse
import io
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

API = "https://www.steamgriddb.com/api/v2"
UA = "Mozilla/5.0 (X11; Linux x86_64; rv:128.0) Gecko/20100101 Firefox/128.0"
HERE = os.path.dirname(os.path.abspath(__file__))
KEEP_EXTS = (".png", ".jpg", ".jpeg")  # Steam renders these as-is; convert others


def _req(url, key=None):
    headers = {"User-Agent": UA, "Accept": "application/json"}
    if key:
        headers["Authorization"] = f"Bearer {key}"
    return urllib.request.Request(url, headers=headers)


def api_get(path, key, params=None):
    url = API + path
    if params:
        url += "?" + urllib.parse.urlencode(params)
    with urllib.request.urlopen(_req(url, key), timeout=30) as r:
        return json.load(r)


def resolve_by_id(kind, asset_id, key):
    """kind in {heroes,grids,logos,icons}; return the asset dict or None."""
    try:
        d = api_get(f"/{kind}/{asset_id}", key)
    except urllib.error.HTTPError as e:
        print(f"  {kind}/{asset_id}: HTTP {e.code}", file=sys.stderr); return None
    if not (isinstance(d, dict) and d.get("success")):
        return None
    data = d["data"]
    return (data[0] if isinstance(data, list) else data) or None


def top_for_game(kind, gid, key, params):
    try:
        items = api_get(f"/{kind}/game/{gid}", key, params).get("data") or []
    except Exception as e:  # noqa: BLE001
        print(f"  {kind}: {e}", file=sys.stderr); return None
    return items[0] if items else None


def save_asset(item, slot, out_dir):
    """Download item['url'], convert to PNG if needed, save as <slot>.<ext>."""
    url = item.get("url")
    if not url:
        return None
    ext = os.path.splitext(urllib.parse.urlparse(url).path)[1].lower() or ".png"
    with urllib.request.urlopen(_req(url), timeout=90) as r:
        raw = r.read()
    if ext in KEEP_EXTS:
        dest = os.path.join(out_dir, slot + ext)
        with open(dest, "wb") as f:
            f.write(raw)
        return dest
    # convert (e.g. .webp) -> .png
    dest = os.path.join(out_dir, slot + ".png")
    try:
        from PIL import Image
        Image.open(io.BytesIO(raw)).save(dest, "PNG")
        return dest
    except Exception as e:  # noqa: BLE001
        # no Pillow / bad image: keep original bytes so nothing is lost
        alt = os.path.join(out_dir, slot + ext)
        with open(alt, "wb") as f:
            f.write(raw)
        print(f"  {slot}: could not convert {ext}->png ({e}); saved {os.path.basename(alt)}",
              file=sys.stderr)
        return alt


def grid_slot(item):
    """Portrait grid -> capsule (library tile); landscape -> wide (Recent Games)."""
    w, h = item.get("width", 0), item.get("height", 0)
    return "wide" if w and h and w > h else "capsule"


def resolve_key(cli_key):
    if cli_key:
        return cli_key
    if os.environ.get("STEAMGRIDDB_API_KEY"):
        return os.environ["STEAMGRIDDB_API_KEY"]
    kf = os.path.join(HERE, "..", "config", "steamgriddb.key")
    return open(kf).read().strip() if os.path.exists(kf) else ""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=os.path.join(HERE, "..", "payloads", "artwork"))
    ap.add_argument("--api-key", default="")
    ap.add_argument("--hero-id"); ap.add_argument("--grid-id")
    ap.add_argument("--wide-id"); ap.add_argument("--logo-id"); ap.add_argument("--icon-id")
    ap.add_argument("--auto", action="store_true", help="pick top-voted art by game name")
    ap.add_argument("--game", default="Bloodborne")
    args = ap.parse_args()

    key = resolve_key(args.api_key)
    if not key:
        print("No API key — use --api-key, $STEAMGRIDDB_API_KEY, or config/steamgriddb.key",
              file=sys.stderr)
        return 2
    os.makedirs(args.out, exist_ok=True)

    picks = {"heroes": args.hero_id, "grids": args.grid_id,
             "logos": args.logo_id, "icons": args.icon_id}
    wide_id = args.wide_id
    got = 0

    # --- explicit-id mode ---------------------------------------------------
    if any(picks.values()) or wide_id:
        for kind, aid in picks.items():
            if not aid:
                continue
            item = resolve_by_id(kind, aid, key)
            if not item:
                print(f"  {kind[:-1]} {aid}: not found"); continue
            slot = grid_slot(item) if kind == "grids" else \
                {"heroes": "hero", "logos": "logo", "icons": "icon"}[kind]
            dest = save_asset(item, slot, args.out)
            if dest:
                print(f"  {slot:8} <- {kind}/{aid}  ({item.get('width')}x{item.get('height')})"
                      f"  -> {os.path.basename(dest)}")
                got += 1
        if wide_id:
            item = resolve_by_id("grids", wide_id, key)
            if item:
                dest = save_asset(item, "wide", args.out)
                if dest:
                    print(f"  {'wide':8} <- grids/{wide_id}  -> {os.path.basename(dest)}")
                    got += 1
        print(f"\ndownloaded {got} asset(s) into {os.path.relpath(args.out)}")
        return 0 if got else 1

    # --- auto mode ----------------------------------------------------------
    if not args.auto:
        print("Nothing to do: pass asset IDs (--hero-id …) or --auto", file=sys.stderr)
        return 2
    games = api_get(f"/search/autocomplete/{urllib.parse.quote(args.game)}", key).get("data") or []
    if not games:
        print(f"No SteamGridDB game for '{args.game}'", file=sys.stderr); return 1
    gid = games[0]["id"]
    print(f"game: {games[0]['name']} (id {gid})")
    static = {"nsfw": "false", "humor": "false", "types": "static"}
    for slot, kind, params in [
        ("capsule", "grids", {**static, "dimensions": "600x900"}),
        ("wide", "grids", {**static, "dimensions": "920x430,460x215"}),
        ("hero", "heroes", static), ("logo", "logos", static),
        ("icon", "icons", {"nsfw": "false", "humor": "false"}),
    ]:
        item = top_for_game(kind, gid, key, params)
        if item and save_asset(item, slot, args.out):
            print(f"  {slot}"); got += 1
    print(f"\ndownloaded {got}/5 slots into {os.path.relpath(args.out)}")
    return 0 if got else 1


if __name__ == "__main__":
    raise SystemExit(main())
