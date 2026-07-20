# DeckBorne

A dedicated installer tool for SteamOS that sets up **Bloodborne** on a **Steam Deck** via the **shadPS4** emulator. 

<p align="center">
  <img src="docs/installer.jpg" alt="DeckBorne installer window" width="820">
</p>

**What's DeckBorne?**
An all-in-one installer specifically built around Steam Deck and SteamOS devices. Installs the ShadPS4 emulator, extracts your personal copy of BloodBornes game dump, applies specific shadPS4 settings, compiles a list of QOL patches and applies them on install directly from emulator repos. You can also drag and drop your downloaded mods from Nexus, GameBanana, or your favorite GH creator directly into the tool! Lastly, the tool adds the BloodBorne tile and artwork to your Steam Shelf, with artwork and icons sourced from SteamGridDB.

> [!CAUTION]
> **<ins>DeckBorne will never provide or link Bloodborne ISO game files. You need to supply
> your own ISO of Bloodborne.</ins>**

<p align="center">
  <img src="docs/installing.jpg" alt="DeckBorne installer running the DeckBorne profile" width="820">
</p>

**Requirements:**
- minimum of 33GB space on internal Steam Deck storage (WiP for 00_preflight to choose storage)
- 1x 64GB USB stick (if using USB method)
- Steam Deck LCD/OLED (LCD model needs more testing, I don't own one myself to validate :( )
- Bloodborne ISO and patch v1.09 of The Old Hunters DLC.
- An internet connection — **required** for the emulator and shadPS4 patches

## Contents

- [Installing and running DeckBorne](#installing-and-running-deckborne)
- [Emulator and profile settings](#emulator-and-profile-settings)
- [Profiles](#profiles)
- [Adding mods](#adding-mods)
- [How/Where the game gets installed](#howwhere-the-game-gets-installed)
- [Layout, Configurations, Pending Validations](#layout-configurations-pending-validations)
- [On AI, Plainly](#on-ai-plainly)

## Installing and running DeckBorne
**USB method (From another PC to the SteamDeck - The way the tool was built):**

*On your computer:*

1. Plug in the USB stick. Download this project (git clone, or the release zip) and copy the
   entire **DeckBorne** folder onto it.
2. Extract the zip to a working location on your computer.
3. Copy your Bloodborne **`.pkg` files** into `DeckBorne/game-pkg/` — the base game, plus the
   v1.09 update if you have it. Filenames don't matter; see
   [What goes in `game-pkg/`](#what-goes-in-game-pkg).
4. Using the **DeckBorne** profile? It requires mods — see [Adding mods](#adding-mods).
   Just want to play? **Vanilla** needs no mods - proceed to next step if using **Vanilla**
5. <a id="install-step-5"></a>Safely eject the stick.

*On your Deck:*

5. **STEAM button > Power > Switch to Desktop.**
6. Plug the stick in and choose **Mount and Open** in the popup, then open the **DeckBorne**
   folder.
7. Double-click **`DeckBorne.desktop`** and choose **Launch** when asked.
8. Pick your profile. The installer says **"Completed"** when it's done — close the windows
   and boot back into Big Picture from the Desktop icon.

You're aiming for this on the stick before you eject:

```
USB stick/
└── DeckBorne/
    ├── DeckBorne.desktop        ← you double-click this on the Deck
    ├── install.sh
    ├── game-pkg/                ← your .pkg files go here
    │   ├── Bloodborne.pkg
    │   └── Bloodborne-update-v1.09.pkg
    └── payloads/
        └── mods/                ← extracted mod folders go here (optional)
            └── vertex-explosion-fix/
```

**Curl method (directly from SteamOS Desktop mode - Alternative way):**

This method assumes you are using your SteamOS device directly as a working PC. 
No USB stick needed for the *tool* — but you still supply your own game dump, so this only
helps if you can get your `.pkg` files onto the Deck another way (SD card, network share,
or a stick you already use for storage).

1. On your Deck: **STEAM button > Power > Switch to Desktop**.
2. Open **Konsole** (the terminal) from the application launcher.
3. Paste this and press Enter:

   ```bash
   curl -fsSL https://raw.githubusercontent.com/JimminyRiggit/DeckBorne/main/scripts/bootstrap.sh | bash
   ```

   That drops a ready-to-run **DeckBorne** folder on your Desktop — about 94 MB (the
   installer plus its UI). Nothing else is installed yet; the emulator patches itself are another
   ~32 MB, downloaded when you run the install.
4. Copy your Bloodborne `.pkg` files into `DeckBorne/game-pkg/`. See
   [What goes in `game-pkg/`](#what-goes-in-game-pkg).
5. Using the **DeckBorne** profile? It requires the Vertex Explosion Fix mod — see
   [Adding mods](#adding-mods). Vanilla needs no mods.
6. Double-click **`DeckBorne.desktop`** in the folder and choose **Launch**.
7. The installer will tell you "Completed" when it's done. Close the windows and boot back
   into Big Picture.

### What goes in `game-pkg/`

| File | What it is | Size | Required? |
|---|---|---|---|
| **Base game** | Bloodborne itself | ~30 GB | **Yes** |
| **Update / patch** | v1.09, which includes The Old Hunters content | ~10 GB | Recommended |

**Filenames and folder structure do not matter.** DeckBorne identifies your dump by
reading the files, not by their names. It searches `game-pkg/` **recursively**, so you can drop
either a folder into `game-pkg/` containing the game file/update file, or just drop your
`Bloodborne.pkg` and `update.pkg` directly into `game-pkg/` without unpacking or renaming
anything. Both of these work:

```
game-pkg/                          game-pkg/
  Bloodborne.pkg                     Some.Release.Name/
  Bloodborne-update-v1.09.pkg          Some.Release.Name.pkg
                                       Some.Release.Name-update.pkg
```

**What happens if the game pkg files arent correctly set?:**

| Situation | Result |
|---|---|
| No `.pkg` found at all | Install **stops** with an error |
| The `.pkg` isn't Bloodborne | **Warns** and continues — other PS4 titles may work, untested |
| No matching update `.pkg` | **Warns** and continues — the base game runs un-patched |
| Two `.pkg`s with different title IDs | The larger becomes the base; the other is ignored |


## Emulator and profile settings

| Component | Value |
|---|---|
| Emulator | shadPS4 **v0.16.0**, Linux **SDL** build (`Shadps4-sdl.AppImage`) |
| Emulator source | Downloaded from the GitHub release at install time, SHA-256 verified |
| Zip SHA-256 | `7cbb19fe…dfc79b` (verified) |
| AppImage SHA-256 | `9c3656ca…8fba1a` (verified) |
| Game | Bloodborne GOTY / Complete Edition, title ID ************** (incl. The Old Hunters DLC) — the title ID is discovered from the PKG header, so other regions work too (NEEDS FURTHER TESTING) |

**Patches are not mods.** shadPS4 reads XML patch files at boot and applies *memory*
patches to the running game — frame-rate, resolution, and QOL tweaks live here.
File-overlay mods are a separate thing (stage 40).

| shadPS4 v0.16.0 | Vanilla | DeckBorne |
|---|---|---|
| Game version | Bloodborne v1.09 | Bloodborne v1.09 |
| **Game patches applied** | **7** | **11** |
| **Frame pacing** (`30 FPS++`) | — | ✅ |
| **Community mods** (stage 40) | — | ✅ |
| `GPU.vblank_frequency` | 60 Hz | 60 Hz |
| `GPU.window_width` / `_height` | 1280 × 800 | 1280 × 800 |
| `GPU.internal_screen_width` / `_height` | 1280 × 800 | 1280 × 800 |
| `GPU.full_screen` | true | true |
| `GPU.full_screen_mode` | Fullscreen | Fullscreen |
| `GPU.present_mode` | Fifo | Fifo |
| `GPU.fsr_enabled` | true | true |
| `General.extra_dmem_in_mbytes` | 2000 | 4000 |
| `General.show_fps_counter` | true | true |
| `Vulkan.pipeline_cache_enabled` | false | false |
| `Log.sync` | false | false |

Please see [Layout, Configurations, Pending Validations](#layout-configurations-pending-validations) for further details on a few of the reasons these settings are defined. Most are standing bugs or errors needing to be remediated or further tested against.

Everything installs under `$HOME` (`~/Applications/shadps4`, `~/Games/shadps4`, `~/.local/share/shadPS4`) so it survives SteamOS updates.

## Profiles
### Vanilla — as close to the original as possible
> *As close to the original experience as possible. No MODs. Target 30 FPS.*

Bloodborne as it shipped, minus what the Deck can't afford. **Nothing here changes how the game plays**.

| Patch | What it does |
|---|---|
| `Resolution Patch 1280x800 (16:10)` | Renders at the Deck's native 1280×800 instead of the PS4's 1920×1080 — roughly half the pixels — with lock-on and HP-bar positions corrected to match. |
| `1280x800 Light Grid For SteamDeck` | Lowers light-grid draw calls at that window resolution. Pure performance, no visual change. |
| `Model LOD 1 (Lower)` | Uses lower-detail character and object models. Performance win; the Deck lacks the headroom that higher detail levels assume. |
| `Increased Graphics Heap Sizes` | Larger graphics heaps. |
| `FMOD Crash Fix` | Audio-engine stability fix. Upstream notes it *"may unintentionally prevent some sound playback"*. |
| `Unlock Game Region` | Unlocks additional language options. Does **not** swap the X/O buttons. |
| `Disable HTTP Requests` | Stops the game phoning home. |

### DeckBorne — the tuned experience - While it runs without MODs, it will not be a good experience
> *QOL improvements, visual enhancements, community mods. Target FPS 30-60fps*

Everything Vanilla applies, **plus** a frame-pacing patch and the three presentation patches
Vanilla leaves out (`Skip Intro`, `Disable Motion Blur`, and `Disable Chromatic Aberration`).

⚠️ **This profile requires the Vertex Explosion Fix mod, which DeckBorne does not ship.**
You download it yourself and drop it in before installing — see [Adding mods](#adding-mods).
Without it, `30 FPS++` makes character faces explode into offscreen vertices. If you'd rather
not deal with mods, install **Vanilla** instead; it has no mod dependency.

| Patch | What it does |
|---|---|
| `30 FPS++` | Tunes frame skip, vsync and tearing for better input response at 30 FPS. **It does not raise the frame rate** — the game still targets 30. |
| `Resolution Patch 1280x800 (16:10)` | Renders at the Deck's native 1280×800 instead of the PS4's 1920×1080 — roughly half the pixels — with lock-on and HP-bar positions corrected to match. |
| `1280x800 Light Grid For SteamDeck` | Lowers light-grid draw calls at that window resolution. Pure performance, no visual change. |
| `Model LOD 1 (Lower)` | Uses lower-detail character and object models. Performance win; the Deck lacks the headroom that higher detail levels assume. |
| `Disable Motion Blur` | Removes motion blur. Performance win as well as a look change. |
| `Disable Chromatic Aberration` | Removes the colour-fringing filter applied over the image. |
| `Increased Graphics Heap Sizes` | Larger graphics heaps. |
| `Skip Intro` | Skips the startup logo sequence. |
| `FMOD Crash Fix` | Audio-engine stability fix. Upstream notes it *"may unintentionally prevent some sound playback"*. |
| `Unlock Game Region` | Unlocks additional language options. Does **not** swap the X/O buttons. |
| `Disable HTTP Requests` | Stops the game phoning home. |

## Adding mods

**Mods are required for the DeckBorne profile.** shadPS4's `30 FPS++` / `60 FPS++` patches
have a known bug that makes character faces explode into offscreen vertices. DeckBorne uses
`30 FPS++` for input latency, so it **requires** the vertex explosion fix mod to be usable.

**DeckBorne does not distribute mods — not even the required one.** Every mod below is
downloaded by you and dropped into `payloads/mods/`. 

### Required — for the DeckBorne profile
| Mod | Link |
|---|---|
| **Vertex Explosion Fix** — required by the DeckBorne profile | [nexusmods.com/bloodborne/mods/109](https://www.nexusmods.com/bloodborne/mods/109?tab=files&file_id=751) |

### Recommended — performance
| Mod | Link |
|---|---|
| Deck 16:10 UI Fix | [mods/207](https://www.nexusmods.com/bloodborne/mods/207?tab=files&file_id=1304) |
| FPS Boost 1.0 | [mods/27](https://www.nexusmods.com/bloodborne/mods/27?tab=files&file_id=214) |
| Bloodborne Reshaded | [mods/27](https://www.nexusmods.com/bloodborne/mods/27?tab=files&file_id=234) |
| Pointlight Removal — fixes brightness, may be too dark on a non-OLED Deck | [mods/27](https://www.nexusmods.com/bloodborne/mods/27?tab=files&file_id=367) |
| Half Cloth Physics w/ Blood | [mods/114](https://www.nexusmods.com/bloodborne/mods/114?tab=files&file_id=1399) |

### Recommended — quality of life
| Mod | Link |
|---|---|
| Elden Ring Style Modern Xbox Prompts | [mods/30](https://www.nexusmods.com/bloodborne/mods/30?tab=files&file_id=1375) |
| More Options At Lamps | [mods/107](https://www.nexusmods.com/bloodborne/mods/107?tab=files&file_id=573) |

### Optional — 60 FPS
Only if you want to try for 60 FPS. The Deck does not reliably hold it.

| Mod | Link |
|---|---|
| 60 FPS Cutscene Fix | [mods/70](https://www.nexusmods.com/bloodborne/mods/70?tab=files&file_id=916) |
| BB 60 FPS Patch | [mods/252](https://www.nexusmods.com/bloodborne/mods/252?tab=files&file_id=1460) |

### How to install a mod

Do this on the computer you're preparing the USB stick from, before you run the installer.

1. Make a free [Nexus account](https://www.nexusmods.com/) and log in — Nexus requires one
   even for manual downloads.
2. Open a mod link from the tables above, click **Free Download**,
3. extract the downloaded `.zip`
4. Drop the extracted folder into `DeckBorne/payloads/mods/` — **exactly as it came out of
   the zip.**
5. Repeat for any other mods, then go back and [**eject the stick**](#install-step-5).

That's it. Using the required mod as the example, you're aiming for this:

```
DeckBorne/
└── payloads/
    └── mods/
        └── vertex-explosion-fix/        ← the folder from the zip, untouched
            └── parts/
                ├── fg_a_0000_l.partsbnd.dcx
                ├── fg_a_0100_l.partsbnd.dcx
                └── …  (144 files)
```

**Don't rearrange anything inside it.** Every mod is packaged differently — some start at
`parts/`, some at `dvdroot_ps4/`, some bury everything a few folders deep. DeckBorne works out
where the files belong by asking your installed game which of them already exist, so nesting
depth and layout don't matter. 

If a mod can't be placed confidently, it's **skipped and logged** rather than guessed at. The
install still finishes and the game still runs.

## Layout, Configurations, Pending Validations

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
game-pkg/               # your dump: base + update .pkg            [gitignored, ~30GB]
logs/                   # per-run logs + state snapshots           [gitignored]
```

## Temporary ShadPS4 settings needing further testing.

- **`present_mode=Fifo`** — vsync is enabled. Alternatives are Mailbox/Immediate, but from logging it seemed that no matter what I set, it would default back to Fifo. Unsure if it's a shadPS4 issue or a Deck issue.
- **`fsr_enabled=true`** — FSR upscaling is **on**. The Deck struggles a bit; need to test this off w/ mods.
- **`extra_dmem_in_mbytes`** — shadPS4 default is zero. Vanilla asks for 2GB, DeckBorne for 4GB — DeckBorne is carrying mods and a frame-pacing patch, so it needs the extra headroom. This is allocating out of the Deck's shared 16GB of memory, so it may cause OOM, which will start whacking processes to save itself. If DeckBorne crashes a lot, try dropping it to 2000 as well.
- **`pipeline_cache_enabled=false`** — the Vulkan pipeline cache is disabled. For some reason I can't get this to work. Launching the emulator, the logs say it works, but shaders will recompile EVERY start. This just makes a bunch of files consuming disk space every time you launch the game.

## How/Where the game gets installed

shadPS4 0.16 **removed its built-in PKG installer** — the SDL build can only launch an
already-extracted game. So stage 20 extracts the `.pkg` files with the
**ShadPs4Plus standalone extractor** (built from shadPS4's own extraction code, so
output is natively compatible; **v1.1** required — it fixes corruption on PKGs >2GB).
The result of the install will extract the game to the below shadPS4 directory:

```
~/Games/shadps4/CUSA03173/eboot.bin          base game
~/Games/shadps4/CUSA03173-UPDATE/eboot.bin   v1.09 update (auto-applied by shadPS4)
```

ShadPS4 Patches are written to `config.json` by the installer, with key names verified
against the shadPS4 0.16 source. The two profiles differ in their patch set, their mods,
and how much extra memory they ask the emulator for.

## On AI, Plainly

I design and build software for a living, and I built this with AI assistance. Both are
true, and I would rather be up front about it.

The overall design choices — what settings and patches to use, the structure of how
`install.sh` reads in the shell scripts, community engagement for mod integration, and the
testing on real hardware against Steam for integration of the art and game into the shelf —
are mine. AI helped me cover ground I could not have covered alone in this time: reading
through shadPS4 documentation and splitting the patching tool out, developing the mod
overlay — the process of how mods are ingested and mapped — creating the UI/AppImage
bundler to be shipped as a desktop executable, and helping me with my ass shell scripts.

What this does not mean is that this tool was built solely off a model saying it worked. It
was built with my own expertise and understanding, and the CORE idea of wanting to make a
simple, all-in-one installer for folks who just want to play their own copies of Bloodborne
on Steam Deck.

**On the art:** If for any reason a creator would like their artwork removed from this project, PLEASE feel free to engage me and I will accommodate immediately and re-adjust

**This code is not available for monetization or resale.** Build freely off DeckBorne's
tools to make your own projects — all I ask is that you credit back.

**Art permissions do not transfer with a fork.** Any approval described above was granted to
DeckBorne specifically, not to projects derived from it. If you fork this repo, remove any
artwork or icons used before publishing and obtain your own permission from each creator.
(DeckBorne ships no mods, so `payloads/mods/` is empty here and nothing needs stripping —
but if you add mods to your fork, they are yours to clear, not ours.)

