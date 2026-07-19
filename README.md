# DeckBorne

A self-contained USB installer that sets up **Bloodborne** on a **Steam Deck** via the
**shadPS4** emulator — installs the emulator, extracts your game dump, applies tuned
settings and (optional) mods, and adds a launcher tile to Steam.

> You supply your own Bloodborne dump. DeckBorne never distributes the game.

## Quick start (on the Deck)

1. Switch to **Desktop Mode**.
2. Plug in the USB stick and open this folder.
3. Run:
   ```bash
   ./install.sh
   ```
4. Switch back to **Game Mode** (or restart Steam) — a **Bloodborne** tile appears.

Run a single stage with e.g. `./install.sh 50`.

## What it installs (pinned)

| Component | Value |
|---|---|
| Emulator | shadPS4 **v0.16.0**, Linux **SDL** build (`Shadps4-sdl.AppImage`) |
| Emulator source | GitHub release asset — also **bundled** at `payloads/shadps4/` for offline installs |
| Zip SHA-256 | `7cbb19fe…dfc79b` (verified) |
| AppImage SHA-256 | `9c3656ca…8fba1a` (verified) |
| Game | Bloodborne GOTY / Complete Edition, title ID **CUSA03173** (EU; incl. The Old Hunters DLC) |
| Config | `isDevKitMode=on`, `vblankDivider=4`, fullscreen (from the reference guide) |

Everything installs under `$HOME` (`~/Applications/shadps4`, `~/Games/shadps4`,
`~/.config/shadps4`) so it survives SteamOS updates, which wipe the system partition.

## Layout

```
install.sh              # orchestrator — runs the stages in order
config/
  deckborne.env         # ← single source of truth: versions, checksums, paths, IDs
  patch_config.py       # section-aware config.toml key setter (dependency-free)
  steamgriddb.key       # SteamGridDB API key for fetch_artwork.py  [gitignored]
scripts/
  lib.sh                # shared logging / checksum / Steam lifecycle helpers
  00_preflight.sh       # env + deps + game-dump + free-space checks
  10_install_emulator.sh# download/bundle → verify → extract → verify
  20_install_game.sh    # extract base + v1.09 update .pkg into the games dir
  30_apply_config.sh    # apply Bloodborne-tuned settings
  40_apply_mods.sh      # merge mod overlays from payloads/mods/
  50_steam_shortcut.sh  # register the Steam tile (+ artwork, + Recent Games warm-up)
  90_collect_logs.sh    # read-only state snapshot for troubleshooting
  99_uninstall.sh       # reverse everything, leaving no stray Steam data
steam/
  add_shortcut.py       # binary shortcuts.vdf reader/writer + localconfig.vdf cleanup
  fetch_artwork.py      # pull tile art from SteamGridDB into payloads/artwork/
payloads/
  shadps4/              # bundled emulator zip (offline install)   [gitignored]
  mods/                 # drop extracted Nexus mods here as <name>/ [gitignored]
  artwork/              # grid/hero/logo/icon/wide images for the tile
game-ISO/               # your dump: base + update .pkg            [gitignored, ~30GB]
```

## Adding mods

Per the reference guide, all mods are manual Nexusmods downloads (some many GB), so
DeckBorne treats them as USB payloads rather than auto-downloads. Extract a mod into
`payloads/mods/<name>/` mirroring the in-game folder layout; `40_apply_mods.sh`
rsync-merges each folder (alphabetical — prefix `00_`, `10_`, … to order them) into
the installed game and records a pre-mod manifest for reference.

## Tile artwork

Drop images into `payloads/artwork/` named exactly (`.png`/`.jpg`):

| File | Steam slot | Where it shows | Canonical size |
|---|---|---|---|
| `capsule` | vertical capsule | library grid tile (your non-Steam games) | 600×900 |
| `wide` | horizontal capsule | **Recent Games**, Big Picture, list view | 920×430 |
| `hero` | hero banner | top of the game's page | 1920×620 |
| `logo` | transparent logo | overlaid on the hero | (free-form) |
| `icon` | small icon | list rows / tooltip | 256×256 |

All five slots matter — a missing `wide` is why a tile can look blank in Recent Games
and Big Picture even when the library tile looks fine.

They're copied into Steam's grid folder named by the shortcut's `appid` (which
DeckBorne sets explicitly, so the art always matches). If the appid ever changes,
stage 50 sweeps the old `<appid>*` files first, so reinstalls self-heal instead of
stranding orphans.

### Fetching art automatically

`steam/fetch_artwork.py` pulls art from **SteamGridDB**. Needs an API key via
`--api-key`, `$STEAMGRIDDB_API_KEY`, or `config/steamgriddb.key` (gitignored).

```bash
# top-voted static art for every slot
python3 steam/fetch_artwork.py --auto --game "Bloodborne"

# hand-pick specific assets by their SteamGridDB IDs (from /hero/<id>, /icon/<id>, …)
python3 steam/fetch_artwork.py --hero-id 34872 --grid-id 82619 --icon-id 70473
```

A portrait grid is saved as `capsule`, a landscape one as `wide`. Non-PNG/JPG art
(e.g. webp heroes) is converted to PNG so Steam renders it. Requests send a browser
User-Agent — the SteamGridDB CDN sits behind Cloudflare and blocks default urllib UAs.

Note `--auto` overwrites every slot, so it will clobber hand-picked art. Fetch to a
throwaway `--out` directory and copy in just the slot you want if you've curated.

## Recent Games (why the installer briefly launches the game)

At the end of stage 50 you'll see **Bloodborne boot on its own for ~15 seconds and
then close**. That's deliberate — it's the only known way to get the tile onto Steam's
**Recent Games** shelf without you launching it yourself.

**Why:** Steam lists a game in Recent Games only once it has *actually launched* it.
The shortcut's `LastPlayTime` field is **ignored** for an appid Steam has never run —
stamping it does nothing. (Verified on-device: a tile with `LastPlayTime` set got a
library tile but never a Recent entry, until the same appid was launched once.)
Steam's own play records live in `localconfig.vdf`, and for non-Steam games they hold
only `Playtime`/`BadgeData` — there is no `LastPlayed` key to write.

So stage 50 boots the tile once through Steam (`steam://rungameid/<gameid>`), waits,
and stops it. Steam does its own bookkeeping and the tile lands in Recent.

The warm-up is best-effort — if it can't run, the install still succeeds and the tile
simply shows up in Recent after your first manual launch. Tunables:

| Variable | Default | Meaning |
|---|---|---|
| `DECKBORNE_WARMUP` | `1` | set `0` to skip the warm-up entirely |
| `DECKBORNE_WARMUP_SETTLE` | `20` | seconds to wait after Steam starts before launching |
| `DECKBORNE_WARMUP_DWELL` | `15` | seconds to leave the game running before stopping it |

## Overriding the tile name

`STEAM_TILE_NAME` can be overridden from the environment — handy for registering a
throwaway tile without editing config:

```bash
STEAM_TILE_NAME=BBTEST ./install.sh 50
```

The name feeds the grid appid, so a new name means an appid Steam has never seen —
which is how first-run tile behaviour gets tested. `uninstall.sh` finds such tiles
regardless of name (see below), so they don't get stranded.

## Uninstall / reset (for clean re-testing)

```bash
bash uninstall.sh              # remove emulator, extracted game, Steam tiles, config.toml
                               #   — KEEPS shadPS4 save data + shader cache, and the USB logs
bash uninstall.sh --all        # also wipe ~/.config/shadps4 + save data (prompts; add -y to skip)
bash uninstall.sh --dry-run    # show exactly what would be removed, change nothing
bash uninstall.sh --purge-logs # also clear old USB log history
```

It's Steam-aware (closes Steam, edits, restarts) and removes **every tile pointing at
our shadPS4 AppImage**, not just the one named `$STEAM_TILE_NAME` — so tiles added
under a throwaway name are cleaned up too. For each tile it removes the shortcut, its
artwork, and **Steam's play records** in `localconfig.vdf` (Steam keys a non-Steam
game under *both* the signed and unsigned appid; leaving those behind stranded a pair
of entries on every uninstall). Pass `--keep-play-records` to preserve playtime.

Default is safe — it only removes things the installer can recreate; `--all` is the
full nuke.

## Logs (permanent, on the USB)

Every run is captured to `logs/` on the USB stick — one timestamped file per run,
**never overwritten**, plus `logs/latest.log` pointing at the newest.

```bash
bash install.sh            # writes logs/deckborne-run-<timestamp>.log
bash install.sh collect    # snapshot shadPS4 logs + config.toml + Steam state
```

`collect` is read-only and safe to run any time — e.g. right after a crash in Game
Mode. It prints shadPS4's logs into the run log *and* copies raw files into
`logs/state-<timestamp>/`, including Steam's `localconfig.vdf` (useful for debugging
tile/Recent-Games behaviour).

> **Note:** `localconfig.vdf` contains Steam **auth tickets** alongside its settings.
> Snapshots stay on the USB (`logs/` is gitignored, so they can't reach a repo), but
> delete old `state-*` directories once you're done with them.

Each log starts with a system report (OS, arch, versions, free space), so a shared log
needs no extra context. Colors are stripped from the file; the live terminal stays
colored.

**Steam only writes `localconfig.vdf` when it exits.** A `collect` taken while Steam
is running reflects Steam's state at its last shutdown, not the present — quit Steam
first if you need current play records.

## How the game gets installed (important)

shadPS4 0.16 **removed its built-in PKG installer** — the SDL build can only launch an
already-extracted game. So stage 20 extracts the `.pkg` files with the
**ShadPs4Plus standalone extractor** (built from shadPS4's own extraction code, so
output is natively compatible; **v1.1** required — it fixes corruption on PKGs >2GB).
The result:

```
~/Games/shadps4/CUSA03173/eboot.bin          base game
~/Games/shadps4/CUSA03173-UPDATE/eboot.bin   v1.09 update (auto-applied by shadPS4)
```

The Steam tile boots `shadps4 -g <…/CUSA03173/eboot.bin> -f true`. These CLI flags
(`-g`, `-f`) were confirmed by reading the 0.16 binary directly.

Extraction is atomic: it unpacks into `~/Games/shadps4/.extract-tmp` and only swaps
the result into place after an `eboot.bin` is verified, so an interrupted run can't
corrupt a working install — and the temp dir is swept on any exit, so a cancelled
extraction doesn't strand ~30GB either.

## Status

**Working, verified on-device (Steam Deck, SteamOS):** full install from USB;
emulator + 30GB base + v1.09 update extraction; config patching; Steam tile with all
five artwork slots; Recent Games via the warm-up launch; uninstall leaving no stray
tiles or Steam records. The game **boots to the opening cutscene and character
creator**, and controls are mapped correctly out of the box.

**Not yet verified:**

1. **v1.09 actually active** — the game boots and runs, but nothing checks in-game
   that the sibling `CUSA03173-UPDATE` folder is being applied rather than silently
   ignored. Fallback if it isn't: extract the update *over* the base folder.
2. **Config keys beyond the three we set** — `General.isDevKitMode`,
   `GPU.vblankFrequency`, `GPU.Fullscreen` are applied; the guide's "shader cache" and
   "40–50 FPS cap" are GUI-side toggles whose 0.16 config keys aren't confirmed (set
   them in-app if wanted).
3. **Mods** — the merge path is written but has never run against a real mod.
