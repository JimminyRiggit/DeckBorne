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
| Game | Bloodborne GOTY / Complete Edition, title ID **CUSA03173** (EU; incl. The Old Hunters DLC) — the title ID is discovered from the PKG header, so other regions work too |
| Config | written to `config.json` with keys verified against the 0.16 source; see **Profiles** below |

Everything installs under `$HOME` (`~/Applications/shadps4`, `~/Games/shadps4`,
`~/.local/share/shadPS4`) so it survives SteamOS updates, which wipe the system partition.

> **shadPS4 0.16 moved its config.** It reads `$XDG_DATA_HOME/shadPS4/config.json`
> (i.e. `~/.local/share/shadPS4`, capital P/S, note the case) — **not** `~/.config/shadps4`,
> and **not** TOML. `src/common/config.cpp` is gone at v0.16.0; settings live in
> `src/core/emulator_settings.cpp` and the JSON keys are the C++ member names verbatim,
> so they are snake_case: `vblank_frequency`, not `vblankFrequency`. Older guides
> describing a `config.toml`, a "vblank divider", or `isDevKitMode` are describing a
> layout this version no longer reads.

## Layout

```
install.sh              # orchestrator — runs the stages in order
config/
  deckborne.env         # ← single source of truth: versions, checksums, paths, IDs, profiles
  patch_config_json.py  # section-aware config.json key setter (dependency-free, type-safe)
  patch_config.py       # DEAD — pre-0.16 config.toml setter, kept only for reference
  mods.catalog          # pointer list of known-compatible mods (URLs only, never files)
  steamgriddb.key       # SteamGridDB API key for fetch_artwork.py  [gitignored]
scripts/
  lib.sh                # shared logging / checksum / Steam lifecycle helpers
  00_preflight.sh       # env + deps + game-dump + free-space checks
  10_install_emulator.sh# download/bundle → verify → extract → verify
  20_install_game.sh    # extract base + v1.09 update .pkg into the games dir
  30_apply_config.sh    # write emulator settings to config.json (profile-dependent)
  35_apply_patches.sh   # fetch + enable shadPS4 game patches (profile-dependent)
  40_apply_mods.sh      # merge mod overlays from payloads/mods/ (reversible)
  50_steam_shortcut.sh  # register the Steam tile (+ artwork, + Recent Games warm-up)
  90_collect_logs.sh    # read-only state snapshot for troubleshooting
  99_uninstall.sh       # reverse everything, leaving no stray Steam data
steam/
  add_shortcut.py       # binary shortcuts.vdf reader/writer + localconfig.vdf cleanup
  fetch_artwork.py      # pull tile art from SteamGridDB into payloads/artwork/
ui/                     # optional QML/PySide6 desktop front-end for the installer
  main.py backend.py    #   launcher + QProcess driver over install.sh
  qml/Main.qml          #   the window
  build-appimage.sh     #   packages the UI into a self-contained AppImage
payloads/
  shadps4/              # bundled emulator zip (offline install)   [gitignored]
  mods/                 # drop extracted mods here as <name>/      [gitignored]
  artwork/              # grid/hero/logo/icon/wide images for the tile
game-ISO/               # your dump: base + update .pkg            [gitignored, ~30GB]
logs/                   # per-run logs + state snapshots           [gitignored]
```

## Profiles

`DECKBORNE_PROFILE` selects which emulator settings and game patches get applied.
Stages 30 and 35 both read it, and an unknown value is a hard error rather than a
silent fallback.

| Profile | Intent |
|---|---|
| `vanilla` | Reference build — stock-ish, the clean baseline to compare against. Skips the mods stage. |
| `deckborne` | The shipping profile (default). Currently **frozen** while tuning happens in `chocolate`. |
| `chocolate` | **Experimental staging lane.** All performance work lands here first; settings get promoted to `deckborne` only after they prove out on hardware. |

```bash
DECKBORNE_PROFILE=vanilla ./install.sh          # full install, vanilla profile
DECKBORNE_PROFILE=chocolate ./install.sh 35     # just re-apply chocolate's patches
```

Profile values live in `config/deckborne.env` (`PATCHES_<PROFILE>`,
`VBLANK_HZ_<PROFILE>`, and the `*_CHOCOLATE` setting overrides). Everything is
env-overridable, so testing a variation needs no file edits.

## Game patches (not mods)

**Patches are not mods.** shadPS4 reads XML patch files at boot and applies *memory*
patches to the running game — frame-rate, resolution, and QOL tweaks live here.
File-overlay mods are a separate thing (stage 40).

Stage 35 fetches `Bloodborne.xml` from the community
[`ps4_cheats`](https://github.com/shadps4-emu/ps4_cheats) repo, writes it to
`~/.local/share/shadPS4/patches/shadPS4/`, generates the `files.json` the emulator
needs, and sets `isEnabled` per profile. It's non-fatal by design — it runs *after* the
~30GB extract, so a dead network must never cost you the install.

We fetch rather than bundle: the upstream patch repos declare no license, so DeckBorne
doesn't redistribute their XML.

**Two traps this stage exists to catch**, both verified against the emulator's source:

- **`files.json` is load-bearing and fails silently.** The emulator iterates every
  subdirectory of `patches/`, reads `files.json`, and matches the running serial. If
  it's missing or unparseable the whole directory is skipped **with no log line**. A
  patch dir that looks perfect can be doing nothing. Stage 35 generates it and reads it
  back.
- **The shipped XML has no `isEnabled` attribute at all** — the (now-removed) Qt
  launcher added it when a user ticked a box. So the attribute is *inserted*; a
  find/replace assuming it exists would match nothing and apply no patches.

⚠ **Patches can conflict, and last-applied wins in XML order — not yours.** Before
adding one, diff its `Address` attributes against the enabled set. `30 FPS++` and
`60 FPS++` share **97** addresses (never both), and `Performance Patch` collides with
the Deck light-grid and LOD patches. `deckborne.env` documents each exclusion.

All Bloodborne patches target game version **01.09**; they won't apply to another.

## Adding mods

Mods are file overlays that merge into the installed game folder. **DeckBorne never
redistributes them** — Nexus's guidelines prohibit re-hosting another author's work, and
most Bloodborne mods are repacked game assets, i.e. derivatives of copyrighted files.
`config/mods.catalog` is therefore a **pointer list**: names, URLs, and install hints,
never files. You download; DeckBorne applies.

Extract a mod into `payloads/mods/<name>/` mirroring the in-game layout (so
`dvdroot_ps4/…` sits at the top). Stage 40 merges each folder alphabetically — prefix
`00_`, `10_`, … to control precedence when two mods touch the same file.

```bash
scripts/40_apply_mods.sh            # apply everything in payloads/mods/
scripts/40_apply_mods.sh --revert   # restore the pre-mods game state
```

Reverting is real, not advisory: every file about to be overwritten is copied to
`<game>.pre-mods/files/` **before** it's written, and added files are tracked so they can
be removed. A mod whose layout can't be placed is **loudly skipped**, never silently
merged one level too deep — the wrapper folder Nexus archives almost always carry
(`CoolMod v1.2/dvdroot_ps4/…`) is auto-descended when its contents clearly match.

**Two traps stage 40 warns about**, both of which produce a mod that applies perfectly
and changes nothing in game:

- **Locale.** Bloodborne keeps per-language copies of menu assets (`menu/engus`,
  `menu/enggb`, …) and reads exactly **one**, chosen by your release region. Most mods
  are authored for the US release. An EU dump reads `menu/enggb` while the mod replaced
  `menu/engus`. The emulator's own log gives it away: `open: path =
  /app0/dvdroot_ps4/menu/<locale>/`.
- **`-UPDATE` shadowing.** shadPS4 applies the update folder *over* the base, so a file
  present in both is served from the update — meaning a mod merged into the base is
  invisible even though every byte landed correctly.

> **Status:** the overlay pipeline is **proven on-device** (verified with a font mod:
> applied, visible in game, reverted cleanly). It is currently **parked** — mods require
> a Nexus account, and this project opted not to depend on one. `payloads/mods/` ships
> empty; the catalog stays as documentation of what's compatible.

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
bash uninstall.sh              # remove emulator, extracted game, Steam tiles, config.json
                               #   — KEEPS shadPS4 save data + shader cache, and the USB logs
bash uninstall.sh --all        # also wipe shadPS4's user dir + save data (prompts; add -y to skip)
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
bash install.sh collect    # snapshot shadPS4 logs + config.json + Steam state
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

**Working, verified on-device (Steam Deck, SteamOS):** full install from USB; emulator
+ 30GB base + v1.09 update extraction; Steam tile with all five artwork slots; Recent
Games via the warm-up launch; uninstall leaving no stray tiles or Steam records. The
game **runs**, and controls are mapped correctly out of the box. The optional UI wrapper
has driven a full install *and* uninstall end-to-end on hardware.

**Settings and patches are verified end-to-end.** `config.json` is written and read back
with exact type checks, and the emulator's own `memory_patcher` log confirms every
enabled patch applied with write counts matching the source XML — so
`deckborne.env` → stage 35 → XML → emulator memory is a proven chain, not an assumption.

**The file-overlay mod pipeline is proven** (a font mod applied, showed in game, and
reverted cleanly) but is **parked** — see *Adding mods*.

### Known limitations on Deck hardware

Both of these were measured here, repeatedly, and are recorded so nobody re-derives them:

- **The Vulkan pipeline cache does not work on shadPS4 v0.16.0.** It writes a profile
  and then rejects it on the next launch (`Pipeline cache isn't compatible with current
  system`), recompiling everything regardless — confirmed across four runs, including a
  profile written minutes earlier by the same device. It is disabled by default;
  leaving it on costs unbounded disk growth for no benefit.
- **`present_mode=Immediate` is unavailable.** The Deck's driver doesn't advertise it,
  so the emulator silently falls back to `Fifo` (it does log this, at
  `vk_swapchain.cpp:219`). Practical consequence: **vsync can't be disabled**, and under
  Fifo the presented frame rate is quantized to the refresh — at 60 Hz vblank you get
  60, 30, 20 or 15 and nothing in between.

### In progress

**Frame-rate tuning in the `chocolate` profile.** 60 FPS was attempted and abandoned
(~45 FPS with heavy judder — consistent with Fifo quantization alternating 60/30). The
profile is currently mid-experiment while a visual-artifacting issue is isolated, so its
patch set changes run to run and **should not be treated as a recommended config**.
`deckborne` stays frozen until it settles.

**Not yet verified:** that the v1.09 update is actually being applied in-game. The game
boots and runs, but nothing checks that the sibling `CUSA03173-UPDATE` folder is used
rather than silently ignored. Fallback if it isn't: extract the update *over* the base.
