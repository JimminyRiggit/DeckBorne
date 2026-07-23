# DeckBorne

A dedicated installer tool for SteamOS that sets up **Bloodborne** on a **Steam Deck** or **SteamOS Device** via the **shadPS4** emulator. 

<p align="center">
  <img src="docs/installer.jpg" alt="DeckBorne installer window" width="820">
</p>

**What's DeckBorne?**
An all-in-one installer specifically built around Steam Deck and SteamOS devices. Installs the ShadPS4 emulator, extracts your personal copy of BloodBornes game files, applies specific shadPS4 settings, compiles a list of QOL patches and applies them on install directly from emulator repos based on the profile you choose. PLay BloodBorne as it was released, or a more tailored PC experience with the DeckBorne profile and MODs. Bring your favorite mods or pull the ones recommended by DeckBorne; profile switching is easy and you can jump between profiles at any time depending how you want to play! Lastly, the tool adds the BloodBorne tile and artwork to your Steam Shelf in big picture mode.

> [!CAUTION]
> **<ins>DeckBorne will never provide or link Bloodborne game files. You need to supply
> your own copy or game files of Bloodborne.</ins>**

**Requirements:**
- minimum of 33GB space on internal Steam Deck storage (WiP for 00_preflight to choose storage)
- 1x 64GB USB stick (if using USB method)
- Steam Deck/SteamOS (LCD model needs more testing, I don't own one myself to validate :( )
- Bloodborne game files and patch v1.09 of The Old Hunters DLC.
- An internet connection. **required** for the emulator and shadPS4 patches to download

## Contents

- [Installing and running DeckBorne](#installing-and-running-deckborne)
- [Emulator and profile settings](#emulator-and-profile-settings)
- [Profiles](#profiles)
- [Adding mods](#adding-mods)
- [Layout, Configurations, Pending Validations](#layout-configurations-pending-validations)
- [On AI, Plainly](#on-ai-plainly)
- [Credits and Sources](#credits-and-sources)

## Installing and running DeckBorne
**USB method (From another PC to the SteamDeck - Standard Installation):**

*On your computer:*

1. Plug in the USB stick. Download the latest release of DeckBorne (git clone, or the [current release](https://github.com/JimminyRiggit/DeckBorne/releases/latest)) and extract the tar file so you have a "DeckBorne" folder.
2. Copy your existing Bloodborne game files into `DeckBorne/game-pkg/`.  See [What goes in `game-pkg/`](#what-goes-in-game-pkg).

**NOTE:** If you plan on using the DeckBorne profile, this REQUIRES the use of MODs. see [Adding mods](#adding-mods) before proceeding!

3. <a id="install-step-5"></a>Safely eject the stick.

*On your Deck:*

4. **STEAM button > Power > Switch to Desktop.**
5. Plug the stick in and choose **Mount and Open** in the popup, then open the **DeckBorne**
   folder.
6. Double-click **`DeckBorne.desktop`** and choose **Launch** when asked.
7. Pick your profile. The installer says **"Completed"** when it's done close the windows
   and boot back into Big Picture from the desktop icon before launching the game.

You're aiming for this on the stick before you eject:

```
USB stick/
└── DeckBorne/
    ├── DeckBorne.desktop        ← you double-click this on the Deck
    ├── install.sh
    ├── game-pkg/                ← your .pkg files go in here
    │   ├── Bloodborne.pkg
    │   └── Bloodborne-update-v1.09.pkg
    └── payloads/
        └── mods/                ← extracted mod folders go here (optional)
            └── vertex-explosion-fix/
```

**Curl method (directly from SteamOS Desktop mode - Alternative way):**

This method assumes you are using your SteamOS device directly as a working PC and have all necessary game files already on device

1. On your Deck: **STEAM button > Power > Switch to Desktop**.
2. Open **Konsole** (the terminal) from the application launcher.
3. Paste this and press Enter:

   ```bash
   curl -fsSL https://raw.githubusercontent.com/JimminyRiggit/DeckBorne/main/scripts/bootstrap.sh | bash
   ```

   That creates a **DeckBorne** folder on your Desktop 
   
4. Copy your Bloodborne `.pkg` files into `DeckBorne/game-pkg/`. See
   [What goes in `game-pkg/`](#what-goes-in-game-pkg).

**NOTE:** If you plan on using the DeckBorne profile, this REQUIRES the use of MODs. see [Adding mods](#adding-mods) before proceeding!

5. Double-click **`DeckBorne.desktop`** in the folder and choose **Launch**.
6. The installer will tell you "Completed" when it's done. Close the windows and boot back
   into Big Picture to launch the game.

### What goes in `game-pkg/`

it doesnt matter the name or the folder structure for your game and patch. just drop them in the game-pkg/ directory.
```
game-pkg/                          game-pkg/
  Bloodborne.pkg                     Some.Release.Name/
  Bloodborne-update-v1.09.pkg          Some.Release.Name.pkg
                                       Some.Release.Name-update.pkg
```

## Emulator and profile settings

*What are patches?** shadPS4 reads XML patch files at boot and applies *memory* patches to the running game. Things like frame-rate, resolution, and QOL tweaks are all applied to the game. These patches were tested and chosen by the developer and cannot be changed (at this time). The idea is to bundle and ship an easy to use installer without tweaking things yourself. Below are the patches for each profile, and what they do.

MODs are a separate thing (stage 40 of the install wrapper).

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

## Profiles

DeckBorne offers two experiences. Vanilla and Deckborne. If for whatever reason you would like to switch profiles, no need to uninstall, simply re-launch the tool and choose the profile, and the tool will switch your profile without reinstalling the game or losing saves!

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

### DeckBorne — the tuneable experience - Needs further testing and validation
> *QOL improvements, visual enhancements, community mods. Target FPS 30-60fps*

Everything Vanilla applies, **plus** a frame-pacing patch and the three presentation patches
Vanilla leaves out (`Skip Intro`, `Disable Motion Blur`, `30 FPS++`, and `Disable Chromatic Aberration`).

⚠️ **This profile requires the Vertex Explosion Fix mod, which DeckBorne does not ship.**
You download it yourself and drop it in before installing. see [Adding mods](#adding-mods).
Without it, `30 FPS++` makes character faces explode. If you'd rather not deal with mods, install **Vanilla** instead; it has no mod dependency. but still benefits from the extra memory overhead and the patches!

| Patch | What it does |
|---|---|
| `30 FPS++` | Tunes frame skip, vsync and tearing for better input response at 30 FPS. **It does not raise the frame rate** — the game still targets 30. FUTURE FEATURE: Choose between `30 FPS++` / `60 FPS++` patches |
| `Disable Motion Blur` | Removes motion blur. |
| `Disable Chromatic Aberration` | Removes the colour-fringing filter applied over the image. |
| `Skip Intro` | Skips the startup logo sequence. |

## Adding mods

**Mods are required for the DeckBorne profile.** shadPS4's `30 FPS++` / `60 FPS++` patches
have a known issue that makes character faces explode. DeckBorne uses
`30 FPS++` for input latency, so it **requires** the vertex explosion fix mod to be usable.

**DeckBorne does not distribute mods — not even the required one.** Every mod below is
downloaded by you and dropped into `/DeckBorne/payloads/mods/` folder. 

### How to install a mod

This HAS to be done before the installer is run. Mods are applied as part of the install of the game.

1. Make a free [Nexus account](https://www.nexusmods.com/) and log in — Nexus requires one
   even for manual downloads.
2. Open a mod link from the tables above, click **Free Download**,
3. extract the downloaded `.zip`
4. Drop the extracted folder into `DeckBorne/payloads/mods/`
5. Repeat for any other mods, then go back and [**eject the stick**](#install-step-5).

## DeckBorne recommended MODs

The below MODS are recommended and hand picked for the DeckBorne Profile experience. Only the first MOD is mandatory for the DeckBorne profile, the rest are optional but the DeckBorne profile was built with these MODs in mind and they are recommended.

### Required for the DeckBorne profile
| Mod | Link |
|---|---|
| **Vertex Explosion Fix** — required by the DeckBorne profile | [nexusmods.com/bloodborne/mods/109](https://www.nexusmods.com/bloodborne/mods/109?tab=files&file_id=751) |

### DeckBorne Profile MODs
| Mod | Link |
|---|---|
| Deck 16:10 UI Fix | [mods/207](https://www.nexusmods.com/bloodborne/mods/207?tab=files&file_id=1304) |
| FPS Boost 1.0 | [mods/27](https://www.nexusmods.com/bloodborne/mods/27?tab=files&file_id=214) |
| Bloodborne Reshaded | [mods/27](https://www.nexusmods.com/bloodborne/mods/27?tab=files&file_id=234) |
| Pointlight Removal — fixes brightness, may be too dark on a non-OLED Deck | [mods/27](https://www.nexusmods.com/bloodborne/mods/27?tab=files&file_id=367) |
| Half Cloth Physics w/ Blood | [mods/114](https://www.nexusmods.com/bloodborne/mods/114?tab=files&file_id=1399) |
| Elden Ring Style Modern Xbox Prompts | [mods/30](https://www.nexusmods.com/bloodborne/mods/30?tab=files&file_id=1375) |

### Recommended (quality of life)
| Mod | Link |
|---|---|
| More Options At Lamps | [mods/107](https://www.nexusmods.com/bloodborne/mods/107?tab=files&file_id=573) |

### Optional — 60 FPS
Only if you want to try for 60 FPS. The Deck does not reliably hold a steady 60FPS, and frame dips may cause latency issues.

| Mod | Link |
|---|---|
| 60 FPS Cutscene Fix | [mods/70](https://www.nexusmods.com/bloodborne/mods/70?tab=files&file_id=916) |
| BB 60 FPS Patch | [mods/252](https://www.nexusmods.com/bloodborne/mods/252?tab=files&file_id=1460) |

## Layout, Configurations, Pending Validations

```
install.sh              # orchestrator — runs the stages in order
config/
  deckborne.env         # ← single source of truth: versions, checksums, paths, IDs, profiles
  patch_config_json.py  # section-aware config.json key setter (dependency-free, type-safe)
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
  shadps4/              # bundled emulator zip (offline install)
  mods/                 # drop extracted mods here
  artwork/              # grid/hero/logo/icon/wide images for the tile
game-pkg/               # your dump: base + update .pkg 
logs/                   # per-run logs + state snapshots
```

## On AI, Plainly

This project started as a simple install wrapper I began building for my dad to play
Bloodborne on his Steam Deck after a conversation of how he wished he could play his own
copy of Bloodborne on PC, as his PS4 failed. As I continued to work on this, I figured
others may be interested in this project too as I waded through online forums and
communities watching folks ask for support on getting Bloodborne to work on Deck, so I
decided to move the project to GitHub and make it public. I figured if I made this tool
with the help of AI, I didn't really create it in the sense of OWNING the code regardless
how much I contributed from my own skillset, and as a result it belongs to the broader
community to enjoy or continue to help make better.

What this does not mean is that this tool was built solely off a model saying it worked. It
was built with my own expertise and understanding, and the CORE idea of wanting to make a
simple, all-in-one installer for folks who just want to play their own copies of Bloodborne
on Steam Deck.

**On the art:** If for any reason a creator would like their artwork removed from this
project, PLEASE feel free to engage me and I will accommodate immediately and re-adjust

**This code is not available for monetization or resale.** Please feel free to build off
DeckBorne's tools to make your own projects — all I ask is that you credit back and support
the devs, artists, and modding community pages listed in this GH as they are the ones doing
the real work to make any of this possible.

## Credits and Sources

**DeckBorne Launcher Background:**

- **Snatti89** — [Instagram](https://www.instagram.com/snatti89/) | [Deviantart](https://www.deviantart.com/snatti89) | [Tumblr](http://snatti.tumblr.com/)

**Modding Community:**

- [rainmakerv2](https://www.nexusmods.com/profile/rainmakerv2)
- [GazuNeveS](https://www.nexusmods.com/profile/GazuNeveS)
- [fromsoftserve](https://www.nexusmods.com/profile/fromsoftserve)
- [Kyoski](https://www.nexusmods.com/profile/Kyoski)
- [goomab](https://www.nexusmods.com/profile/goomab)
- [CocaGeladinhaHmm](https://www.nexusmods.com/profile/CocaGeladinhaHmm)
- [GAMESMARK](https://www.nexusmods.com/profile/GAMESMARK)
- [Dziggy](https://www.nexusmods.com/profile/Dziggy)

**Steam Artwork:**

- [TUFKAC](https://www.steamgriddb.com/profile/76561198374208390)
- [Morente](https://www.steamgriddb.com/profile/76561197970305233)
- [Miguelmo](https://www.steamgriddb.com/profile/76561198831723485)
- [CluckenDip](https://www.steamgriddb.com/profile/76561198120642113)
- [superrrrrrrrrrr](https://www.steamgriddb.com/profile/76561199052801027)

