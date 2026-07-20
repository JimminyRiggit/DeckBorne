# DeckBorne

A dedicated installer tool for SteamOS that sets up **Bloodborne** on a **Steam Deck** via the **shadPS4** emulator. 

<p align="center">
  <img src="docs/installer.jpg" alt="DeckBorne installer window" width="820">
</p>

**Whats DeckBorne?**
An all in one installer for SteamDeck and SteamOS devices. Installs the emulator, extracts your game dump, applies shadPS4 settings, compiles a list of QOL patches and applies on install directly from emulator repos, and you can drag and drop your downloaded mods from Nexus, Game Banana, or your favorite GH creator. Lastly, the tool adds a launcher tile to Steam Big Picture and pulls art compiled out of SteamGridDB.

**DeckBorne will never provide or link BloodBorne ISO game files. You need to supply your own ISO of BloodBorne**

<p align="center">
  <img src="docs/installing.jpg" alt="DeckBorne installer running the DeckBorne profile" width="820">
</p>

**Requirements:**
- minimum of 33GB space on internal SteamDeck Storage (WiP for 00_preflight to choose storage)
- 1X 64GB USB Stick (if using USB Method)
- SteamDeck LCD/OLED (LCD Model needs more testing, i dont own one myself to validate :( )
- BloodBorne ISO and Patch v1.09 of The Old Hunters DLC.

## Contents

- [Installing and running DeckBorne](#installing-and-running-deckborne)
- [Emulator and profile settings](#emulator-and-profile-settings)
- [Profiles](#profiles)
- [Adding mods](#adding-mods)
- [How/Where the game gets installed](#howwhere-the-game-gets-installed)
- [Layout and Configurations](#layout-and-configurations)

## Installing and running DeckBorne
**USB method (From another PC to the SteamDeck):**
1. On your main computer, plug in the 64GB USB stick.
2. Download this project (git clone or download the release) and move the ENTIRE "DeckBorne" folder/directory to the USB stick.
3. Copy your Bloodborne **`.pkg` files** into the `game-pkg` directory under the "DeckBorne" folder/directory — the base game, plus the v1.09 update if you have it. Filenames don't matter. See [What goes in `game-pkg/`](#what-goes-in-game-pkg) below.
4. PLEASE NOTE: If you aren't planning on using mods and just want to play Bloodborne, install the **Vanilla** profile — the **DeckBorne** profile requires mods to work well. If you want mods, see [Adding mods](#adding-mods) before continuing.
5. <a id="install-step-5"></a>Safely Eject the USB stick from your computer.
6. Wake your SteamDeck and click the "STEAM" button on your Deck > Power > Switch to Desktop
7. Plug in the USB stick - a window will popup asking you to "Mount and Open".
8. Using the trackpad, click the USB stick with DeckBorne.
9. Find the DeckBorne folder on the USB and doubleclick into it.
10. **Double-click `DeckBorne.desktop`** — the desktop launcher. A pop-up window will ask how you want to perform the action, choose "Launch".
11. DeckBorne installer will launch allowing you to choose the experience.
12. Installer will tell you "Completed" once done. When finished, close all windows and boot back into Big Picture using the icon on your SteamOS Desktop.
    
Curl method (directly from SteamDeck Desktop mode):



### What goes in `game-pkg/`

| File | What it is | Size | Required? |
|---|---|---|---|
| **Base game** | Bloodborne itself | ~30 GB | **Yes** |
| **Update / patch** | v1.09, which includes The Old Hunters content | ~10 GB | Recommended |

**Filenames and folder structure do not matter.** DeckBorne identifies your dump by
reading the files, not by their names.  It searches `game-pkg/` **recursively**, so you can drop either a folder into "game-pkg/" containing the game file/update file, or just drop your BloodBorne.pkg and update.pkg directly into "game-pkg/"
without unpacking or renaming anything. both of these work:

```
game-pkg/                          game-pkg/
  Bloodborne.pkg                     Some.Release.Name/
  Bloodborne-update-v1.09.pkg          Some.Release.Name.pkg
                                       Some.Release.Name-update.pkg
```

**What happens if something's off:**

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
| Emulator source | GitHub release asset — also **bundled** at `payloads/shadps4/` for offline installs |
| Zip SHA-256 | `7cbb19fe…dfc79b` (verified) |
| AppImage SHA-256 | `9c3656ca…8fba1a` (verified) |
| Game | Bloodborne GOTY / Complete Edition, title ID ************** (incl. The Old Hunters DLC) — the title ID is discovered from the PKG header, so other regions work too (NEEDS FURTHER TESTING) |

Everything below is written to `config.json` by the installer, with key names verified
against the shadPS4 0.16 source. The two profiles differ in their patch set, their mods,
and how much extra memory they ask the emulator for.

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

Please see [Layout and Configurations](#layout-and-configurations) for further details on a few of the reasons settings are defined. Most are standing bugs or errors needing to be remediated or further tested against

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

Everything Vanilla applies, **plus** a frame-pacing patch and the three presentation patches. Vertex Explosion mod fix is applied by default.
Vanilla leaves out (`Skip Intro`, `Disable Motion Blur`, and `DIsable Chromatic Aberration`)

PLEASE NOTE: This is the profile that applies community mods and was designed with the expectation users will utilize mods. If you are experiencing issues on the base profile, please (see [Adding mods](#adding-mods)). Else, use the Vanilla version.

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

DeckBorne never redistributes mods — you download them yourself and drop them in. Everything
below is free; Nexus needs a free account. Support the authors: endorse the mods you use.

### Included By Default

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

1. Go to [nexusmods.com](https://www.nexusmods.com/) and create a free account, then log in.
2. Open the mod's link from the tables above and click **Free Download**.
3. Extract the downloaded `.zip`.
4. Move the extracted folder — **as-is, don't rearrange it** — into
   `DeckBorne/payloads/mods/<mod-name>/`.
5. Repeat for any other mods you want.
6. Return to [**step 5**](#install-step-5) of the install instructions above.

DeckBorne works out where each mod's files belong by asking the installed game which of them
already exist, so nesting depth and folder layout don't matter. A mod that can't be placed is
**skipped and logged**, never guessed at — the install still completes and the game still runs.

```
## Layout, Configurations, Pending Validations

```
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

- **`present_mode=Fifo`** — vsync is enabled. Alternatives are mailbox/immediate - but from logging it seemed that no matter what I set, it would default back to fifo. unsure if shad issue or if Deck issue.
- **`fsr_enabled=true`** — FSR upscaling is **on**, the Deck struggles a bit, need to test this off w/ mods.
- **`extra_dmem_in_mbytes`** — ShadPS4 default is zero. Vanilla asks for 2GB, DeckBorne for 4GB — DeckBorne is carrying mods and a frame-pacing patch, so it needs the extra headroom. this is allocatting shared 16GB of the Deck memory, so it may cause OOM, which will start whacking processes to save itself. If DeckBorne crashes a lot, try dropping it to 2000 as well.
- **`pipeline_cache_enabled=false`** — the Vulkan pipeline cache is set to disabled. For some reason I cant get this to work. Launching the emulator the logs say it works, but shaders will recompile EVERY start. This just makes a bunch of files consuming space to disk everytime you launch the game.

## How/Where the game gets installed

shadPS4 0.16 **removed its built-in PKG installer** — the SDL build can only launch an
already-extracted game. So stage 20 extracts the `.pkg` files with the
**ShadPs4Plus standalone extractor** (built from shadPS4's own extraction code, so
output is natively compatible; **v1.1** required — it fixes corruption on PKGs >2GB).
The result of the install will extract the game to the below shadPS4 directory:

```
~/Games/shadps4/CUSA03173/eboot.bin          base game
~/Games/shadps4/CUSA03173-UPDATE/eboot.bin   v1.09 update (auto-applied by shadPS4)
