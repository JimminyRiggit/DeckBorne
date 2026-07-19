# HANDOFF — read this first to resume

Last updated: 2026-07-18. This is the "pick up exactly here" doc. Deeper detail lives in
`CLAUDE.md` (Known bug + Recently fixed sections); this is the short version + the one
thing that's mid-flight.

## ▶ RIGHT NOW: the `chocolate` profile — performance tuning, mid-flight

**This is the active work.** The UI section below is the *previous* focus and is done.

### What chocolate is

A THIRD profile alongside `vanilla` and `deckborne`, added 2026-07-18. **It is the
DEV/STAGING lane — every performance experiment lands here first.**

- **vanilla** — stock-ish reference. Leave it alone; it is the only clean baseline, and
  the UI offers it to users as "Vanilla".
- **deckborne** — the shipping profile. **FROZEN BY USER DECISION. Do not "fix" it.**
- **chocolate** — staging. **chocolate is what deckborne will eventually become**;
  settings get promoted only after they prove out on-device.

⚠ A gap in deckborne was found and deliberately LEFT ALONE under this rule:
`PATCHES_DECKBORNE` is a single patch while vanilla has six, so deckborne currently
renders at PS4-native 1080p with no frame-rate patch and is the **slowest of the three**.
An inline comment in `deckborne.env` claiming deckborne "differs from vanilla only by the
absence of 30FPS++" is inaccurate. **Report it, don't fix it** — the fix reaches deckborne
by promotion from chocolate, not by editing deckborne.

CLI-only: `ui/backend.py` does NOT offer chocolate, deliberately.

### ▶▶ DO THIS FIRST — the USB is synced and waiting (end of 2026-07-18)

**The stick already has the build to test. Nothing needs editing before you run it.**

```
DECKBORNE_PROFILE=chocolate ./install.sh 30
DECKBORNE_PROFILE=chocolate ./install.sh 35
```
Expect `ENABLED=10`, `present Fifo`, and **no `FPS++` patch in the list**. Then play and
answer ONE question: **is the artifacting still there?**

**This is a DIAGNOSTIC BUILD, not a shipping config** — see the loud block above
`PATCHES_CHOCOLATE` in `deckborne.env`. The frame-rate patch is deliberately absent, so the
game runs stock pacing and loses the input-latency/frame-skip work `30 FPS++` provides.
Do not promote anything from this state.

**How to read the result:**

| Outcome | Meaning | Next move |
|---|---|---|
| **Artifacting GONE** | It is the `FPS++` family — a deltatime artifact, i.e. vertex explosion | Mods must come OUT OF PARKED. Get the Nexus vertex-explosion fix, then restore `30 FPS++` **and** apply the mod together. Answers "are mods mandatory?" with evidence. |
| **Artifacting STAYS** | Not deltatime. The mod will not help. | Next suspect is `GPU.fsr_enabled=true` — an UPSCALER, shimmer/edge artifacts are its signature, and **chocolate is the first profile that ever wrote this key**. Then `extra_dmem_in_mbytes=4000`, then the `Increased Graphics Heap Sizes` patch. **One at a time.** |

⚠ `Model LOD 1 (Lower)` is **INTENTIONALLY STILL IN**. It is the *other* artifacting
suspect and gets its own run once this one resolves. Pulling both at once would have made
the result unreadable. Do not remove it as "cleanup".

### Current state of the profile

**10 patches**, no frame-rate patch (diagnostic — see above). Names verified against the
live upstream XML, **zero shared addresses** (fully additive).

Settings: `present_mode=Fifo` · `pipeline_cache=false` · `extra_dmem_in_mbytes=4000` ·
`fsr_enabled=true` · `Log.sync=false` · `vblank=60`.

**History, newest first — both restore strings live in `deckborne.env` (no git yet):**
1. **Dropped `30 FPS++`** (current) — diagnostic for the artifacting, above.
2. **Pivoted 60 → 30 FPS.** At 60 the Deck sat ~45 FPS with heavy judder. Ran on-device
   with all 11 patches confirmed applied by `memory_patcher`, write counts matching the XML
   exactly — the chain env → stage 35 → XML → emulator memory is **PROVEN**. Verdict on how
   30 actually *felt* was never collected; the artifacting took priority.
3. **60 FPS original.** Exact patch string preserved in the RECOVERY comment.

⚠ **The 30 FPS question is still genuinely open.** We never learned whether a locked 30
holds, because the artifacting interrupted. When the artifacting is resolved, that is the
next thing to answer: **a clean locked 30 confirms the Fifo-quantization theory below; a
wobbly 25-35 means the frame target was never the bottleneck.**

### Two hardware facts now SETTLED — don't re-litigate either

1. **The Vulkan pipeline cache does not work on shadPS4 v0.16.0. Four consecutive
   failures.** The cleanest test: run 1 wrote a fresh `profile.bin` from this exact device
   ("Cache dumped"), run 2 twenty minutes later read it and **rejected** it —
   `vk_pipeline_serialization.cpp:318 WarmUp: Pipeline cache isn't compatible with current
   system.` Same device, same build, nothing changed between. Compile counts prove it saved
   nothing (291 shaders/187 pipelines vs 275/174). It is now `false`. Cost of leaving it on
   is NOT neutral — `cache_storage.cpp` has no size limit and no eviction, so it writes
   hundreds of files per launch forever and never reads them. **Re-test only after a
   shadPS4 UPDATE, and only trust a log line reading `Preloaded N pipelines` — absence of
   the warning is NOT success** (run 1 had no warning purely because no file existed yet).
   Never tested: `Vulkan.pipeline_cache_archived`.
2. **`present_mode=Immediate` is UNAVAILABLE on this Deck — "disable vsync" is not
   achievable.** All four chocolate runs logged `vk_swapchain.cpp:219 FindPresentMode:
   Requested present mode Immediate is not supported, falling back to Fifo.` The driver
   doesn't advertise IMMEDIATE for this surface, so chocolate ran **Fifo** from its very
   first sync — every perf observation was made under Fifo. Now set to Fifo explicitly so
   the config stops lying. shadPS4 accepts EXACTLY `Mailbox|Fifo|Immediate` (verified in
   `vk_swapchain.cpp:192`); Vulkan's `FIFO_RELAXED` is **not** exposed.
   **⚠ This likely explains the whole "45 FPS with slowdown" report.** Under Fifo,
   presentation is QUANTIZED to the refresh — at vblank 60 you get 60, 30, 20 or 15 and
   nothing between. ~45fps of work therefore alternates 60/30/60/30: the counter reads ~45
   while it FEELS like constant judder. If the Deck renders 30 comfortably, Fifo paces a
   clean locked 30 — which should feel far better than "45" suggests. **Confirming that is
   the point of the next run.**

### Bug fixed while building this (don't reintroduce)

`install.sh`'s `profile_stages()` is consumed as `mapfile -t run_list < <(profile_stages)`
— a **process substitution, i.e. a SUBSHELL**. A `die` inside it exits only the subshell:
`mapfile` reads zero lines, `run_list` comes back EMPTY, the stage loop never executes, and
**install.sh exits 0 having run NOTHING**. Demonstrated live. Profile validation therefore
lives in `require_known_profile()`, called in the PARENT shell and covering BOTH the
full-install and single-stage paths, plus an empty-list assertion after the mapfile. The
`*)` inside `profile_stages` is deliberately NOT a `die`. Same family as the warm-up bug:
a failure a cheerful exit code hides.

Stages 30 and 35 also had a `*)` catch-all that silently gave an unknown profile
deckborne's settings — now explicit cases that `die`.

### Levers not yet pulled (all clash-checked, fully additive)

`Disable Dynamic Light Shadows` ("stops a ton of heavy draw calls" — biggest expected win)
· `Disable SSAO` · `Disable DoF` · `Disable AA` · `Model LOD 2 (Lowest)` (one step below
the current `Model LOD 1 (Lower)`; they are alternatives, NEVER both).
⚠ Note the direction: the source Reddit post ran `Model LOD -2 (Highest)` because an RX
6800 has headroom. On a Deck that **inverts** — go lower, not higher.
⚠ `Performance Patch (perf increase)` stays EXCLUDED — it clashes with four members of the
current set (Light Grid 2 addrs, 30 FPS++ 5, 60 FPS++ 5, Model LOD -2 1).

### Working note on where truth lives

`config.json` is **not** evidence of what the emulator is doing — `shad_log.txt` is. The
env's claim that present-mode fallbacks happen "silently" was WRONG (both are logged), and
believing it is what let chocolate run four sessions on Fifo while its config said
Immediate. Always confirm effective state from the emulator's own log.

## Previous focus: UI wrapper (`ui/`) — design + wiring + packaging DONE on the dev box

A QML + PySide6 desktop front-end for the installer lives in `ui/`. It is the current
focus and Steam-restart saga is CLOSED (see the DONE section).

**◆ SAVE STATE 2026-07-18 — where we are:** the whole UI is built, wired to the real
pipeline, and packaged as a self-contained AppImage. **FULL END-TO-END CONFIRMED ON-DEVICE
2026-07-18:** built on the Deck (`ui/build-appimage.sh`), launched (`ui/run.sh`), and a real
**Install AND Uninstall both ran to completion through the UI** — the tool works top to
bottom on real hardware. Packaging/deployment CLOSED; QProcess wiring proven on-device (not
just via stub). **Remaining work is polish/features** (profile config, uninstall confirm),
not infrastructure.

File map: `ui/main.py` launcher · `ui/backend.py` Installer/StageModel + QProcess driver ·
`ui/qml/Main.qml` the window · `ui/run.sh` launcher · `ui/build-appimage.sh` +
`ui/appimage/` the AppImage recipe · `ui/art` `ui/fonts` `ui/icon.png` assets ·
`DeckBorne.desktop` double-click launcher. Dev deps are in a gitignored `.venv-ui/`.

**Done & verified on the aarch64 dev box** (the emulator/Steam still can't run here, but
the UI layer fully can — that's why PySide6 was chosen):
- `ui/main.py` (launcher) · `ui/backend.py` (Installer QObject + StageModel) ·
  `ui/qml/Main.qml` (frameless glassy window). Preview live with `ui/run.sh`; render a
  PNG headlessly with `ui/run.sh --shot out.png` (add `--running` for the in-progress
  view, `--open N` to force option-card N expanded, `--mock` to fake a run).
- Sleek window: blood-moon art (`ui/art/…jpg`) as a translucent background, the
  **DeckBorne** wordmark in the bundled `fleshandblood` font (`ui/fonts/`, loaded via
  FontLoader so it ships to the Deck), three hover-to-expand option cards (smooth
  accordion + rotating chevron + accent bar), and a progress view (stage checklist +
  red→gold bar).
- Three actions wired to the REAL pipeline via QProcess: **Install Vanilla**, **Install
  DeckBorne**, **Uninstall** (+ a small "Collect logs"). Install runs `install.sh` with
  `DECKBORNE_PROFILE=vanilla|deckborne`; uninstall/collect run its sub-commands.
- Progress is driven by `@@DBUI STAGE <idx> <start|done|fail>` markers that `install.sh`
  now emits (gated on `DECKBORNE_UI=1`, so terminal runs never see them). Verified with
  a marker stub: success path (all done, 100%, "Done"), failure path (stage marked
  failed, "Failed"), and profile stage counts (vanilla 5 / deckborne 6) all pass.

**Packaging SOLVED — self-contained AppImage (like shadPS4's).** No PySide6/Python is
installed on the user's Deck; nothing is left behind. `ui/build-appimage.sh` bundles
Python + Qt6 + PySide6-Essentials + the QML/art/font assets into one file,
`payloads/ui/DeckBorne-<arch>.AppImage` (~89 MB). Base is manylinux2014 (glibc 2.17) so it
runs on any SteamOS. **Built + launched successfully on the Deck 2026-07-18** (also
validated on the aarch64 dev box).

**Build (one-time per machine, needs internet), then launch:**
```
cd /run/media/deck/<stick>/DeckBorne     # wherever the stick mounts
bash ui/build-appimage.sh                # ~few min; downloads base python + PySide6 once
bash ui/run.sh                           # ← this launched it on the Deck
```
Produces `payloads/ui/DeckBorne-x86_64.AppImage`. Launch also works via double-clicking
**`DeckBorne.desktop`** at the stick root, or the `.AppImage` directly (it self-resolves
the pipeline root from `$APPIMAGE`). `ui/run.sh` sets `DECKBORNE_ROOT` and has a noexec-USB
fallback (stages a copy to tmpfs). The build artifact is gitignored; `ui/` source +
`install.sh` + `DeckBorne.desktop` are synced to the stick.

**DONE 2026-07-18 (dev-box validated; pending on-device confirmation):**
- **Filename-independent game detection.** `game-ISO/` discovery now reads PS4 PKG headers
  (magic `7f434e54`, content-id at 0x40) to identify the game by CONTENT, not filename:
  `discover_base_pkg` (largest valid `.pkg`), `discover_update_pkg` (largest other `.pkg`
  with the same title-id), `pkg_title_id`/`pkg_content_id`/`pkg_is_bloodborne` — all in
  `lib.sh`. `GAME_TITLE_ID` is auto-derived from the base pkg (config value is now just a
  fallback; the globs are optional overrides, blanked by default). Validated against the
  real dump (base 30G→CUSA03173, update matched, Bloodborne confirmed). Extraction folders
  + `.boot_target` + stage-40 manifest all use the derived id.
- **Live extraction progress.** `20_install_game.sh` backgrounds the extractor and samples
  `.extract-tmp` size vs the `.pkg` size every 4 s, emitting `@@DBUI SUBPROGRESS <0..1>`
  (+ a human `extracting … N%` line for the terminal). `ui_event` moved to `lib.sh` so
  stages can emit it. UI (`backend.py`) parses SUBPROGRESS to advance the bar WITHIN the
  Extract stage (verified end-to-end: bar at 39% mid-extract instead of frozen at 33%).
- **UI polish (2026-07-18):** raw install.sh log lines are no longer surfaced in the UI
  (they go to the run log only); each stage shows a friendly message (`STAGES_*` are now
  `(label, message)` tuples in `backend.py`), the Extract stage shows a rotating panel of
  Bloodborne quotes (fade out/in every 5s) in the space right of the checks, and on finish
  the action button becomes **"Completed"** (returns to the menu). `quoting` property +
  quote list live in `backend.py`/`Main.qml`.
- **⚠ Rebuild needed for the UI changes:** `backend.py` AND `qml/Main.qml` are bundled
  INSIDE the AppImage, so re-run `bash ui/build-appimage.sh` on the Deck to pick up the
  SUBPROGRESS bar, friendly messages, quotes, and completion button. The pipeline scripts
  (discovery, progress emission) are read live from the USB — already synced — so those
  take effect on the next install with no rebuild.

**DONE 2026-07-18 (afternoon) — patches + mod safety. Dev-box tested, NOT YET SYNCED
to the stick (it was unmounted at the time) and NOT YET run on the Deck.**

⚠ **FIRST ACTION NEXT SESSION: sync these to the stick** — `install.sh`,
`config/deckborne.env`, `scripts/35_apply_patches.sh`, `scripts/40_apply_mods.sh`,
`ui/backend.py`. The repo is ahead of the stick.

- **NEW stage 35 (`35_apply_patches.sh`) — this is what finally makes the profiles
  differ.** shadPS4 applies *memory* patches from an XML it reads at boot; that's where
  frame-rate/QOL live, and it is NOT the same thing as the file-overlay mods in stage 40.
  Stage 35 fetches `PATCHES/Bloodborne.xml` from `shadps4-emu/ps4_cheats` (anonymous, no
  account, ~200KB), writes it + a generated `files.json` to
  `~/.local/share/shadPS4/patches/shadPS4/`, sets `isEnabled="true"` on the profile's
  patches and `"false"` on all others, then re-reads both files to verify.
  - **BOTH profiles get `1280x800 Light Grid For SteamDeck (READ NOTES)`** — pure
    performance ("lowers Light grid draw calls"), no gameplay change, and 1280x800 is the
    Deck's native panel. ⚠ It is RESOLUTION-KEYED (1080p/1440p/4k variants exist) and the
    note says to match your WINDOW/FULLSCREEN resolution — so this is wrong for DOCKED
    play. Handheld is the target; revisit if docked ever becomes supported.
  - **vanilla additionally gets `30 FPS++`.** Per its author's note it does NOT change
    frame rate — it "changes some frame settings like the frame skip, vsync, frame
    tearing" for better "input delay/response times for 30 FPS". A responsiveness fix,
    hence vanilla-safe.
  - **deckborne's frame-rate patch is still TODO**, so right now deckborne differs from
    vanilla only by the ABSENCE of 30FPS++. The 60 FPS patch's own note warns "game speed
    might slow if you drop below 60 fps" — needs on-device tuning before it ships.
  - **Hidden from the UI.** `UI_HIDDEN_STAGES` in `install.sh`: hidden stages run and log
    normally but emit no `@@DBUI` marker and don't advance the marker index, so visible
    numbering stays 1..5 (vanilla) / 1..6 (deckborne) and `ui/backend.py`'s stage lists
    need no change. Verified with stubbed stages on both profiles.
  - **Non-fatal by design** — it runs after the ~30GB extract, so no network must never
    cost the user their install. Warns loudly, exits 0, re-runnable standalone.
  - Traps it guards (all verified against emulator source): `files.json` missing/bad →
    the emulator skips the WHOLE patch dir **with no log line**; the shipped XML has **no
    `isEnabled` attribute at all** (must be inserted, not flipped); path is
    `~/.local/share`, not `~/.config`; portable mode (`user/` in CWD) redirects where the
    emulator looks; every Bloodborne patch is `AppVer 01.09`.
- **`40_apply_mods.sh` hardened.** The old "backup" wrote only a LIST of filenames, so an
  overwritten vanilla file was gone forever. Now: real content backup to
  `<game>.pre-mods/files/` before each overwrite (first write wins, so a later mod can't
  clobber the pristine copy), added-file tracking, a working **`--revert`**, and layout
  validation that auto-descends a single Nexus wrapper folder and loudly SKIPS anything
  unplaceable. Summary reports `applied N — M SKIPPED` rather than a cheerful count.
  Verified on a simulated tree: good/wrapped/junk mods all handled, revert restores the
  pristine manifest exactly.
- **Mods can't be automated and that's settled.** Nexus requires a login even for manual
  browser downloads; the API's `download_link.json` is premium-only for bare calls (free
  accounts need a website-minted key via an `nxm://` handshake). Redistributing mod files
  ourselves is against Nexus ToS. So: **patches are fetched, mods are user-dropped.**
  Don't relitigate this — see the research summary in the session notes.
- **Never vendor the patch XML.** `shadps4-emu/ps4_cheats` and `illusionyy/PS-Game-Patch`
  declare **no license**. Fetch at install time, which is also what keeps the AppImage
  small (a user requirement: mods/patches must not bloat the shipped artifact).
- **Note:** the emulator's own patch downloader UI was removed when Qt was dropped (it
  lives in the separate `shadps4-qtlauncher` repo now). The SDL build we ship has no
  downloader, but the core still auto-applies patches at boot — so writing the files
  ourselves is the supported path, not a workaround.
- **Spotted for later:** the XML contains a `1280x800 Light Grid For SteamDeck` patch —
  an obvious deckborne-profile candidate when that gets tuned.

**DONE 2026-07-18 (late) — patches PROVEN working; config.toml had NEVER applied.**

Chasing "vanilla doesn't feel smoother" found three real bugs. Patches were not among them.

- **✓ PATCHES CONFIRMED APPLYING ON-DEVICE.** `shad_log.txt` from the 13:14 collect:
  `memory_patcher.cpp:361 PatchMemory: Applied patch: 30 FPS++, Offset: …` — **97 writes
  for `30 FPS++`, 2 for the Light Grid**. Stage 35 works end to end. Don't re-investigate.
- **✓ v1.09 VERIFIED IN-GAME** — the emulator's own boot log prints
  `Game id: CUSA03173 Title: Bloodborne™` / `App Version: 01.09`. This closes the
  long-standing README/CLAUDE.md TODO. The base+`-UPDATE` sibling layout does work.
- **✗ config.toml was INVALID TOML on every install and shadPS4 silently ran on
  DEFAULTS.** `patch_config.py` appended a new section as ONE multi-line string, so the
  next set_key() couldn't see the header (`"[GPU]\nkey = v"` ends in the value, not `]`)
  and appended a SECOND `[GPU]`. Duplicate tables are invalid TOML.
  - **Why it hid for weeks: the default `vblankFrequency` IS 60** — the value we were
    trying to set. The one setting anyone checked always looked correct.
  - **The tell:** the file said `isDevKitMode = true` while the emulator's boot log said
    `isDevKit: false`. A config key that disagrees with the emulator's own log is proof
    the file was rejected.
  - **First fix was WRONG and made it worse** — collapsing duplicate sections AFTER
    set_key turned a duplicate TABLE into a duplicate KEY (`Fullscreen` twice), still
    invalid. Order matters: **heal first, then set keys.** Now also dedupes keys within a
    section (last value wins, first position kept). Idempotent over repeated runs.
  - **Stage 30 now PARSES the result with `tomllib`** instead of grepping for a line — a
    grep passes on a file TOML rejects. Verified on-device 13:18: `config.toml validated`.
- **✗ `vblankFrequency` is HZ, not the old divider.** We were writing `4` (a divider-era
  value); 0.16 reads it as 4 Hz and clamps to 60. Accidentally right for 30 FPS, silently
  wrong for any high-FPS profile. Now profile-aware and written in real Hz. **Pairing rule
  from the patch authors: 30/60 FPS++ -> 60; `90 FPS++` -> 90+; Uncap -> higher.**
- **✗ `90_collect_logs.sh` could never find shadPS4's log** — it searched `-iname '*.log'`
  but shadPS4 writes **`shad_log.txt`**, so every collect reported "no log files found"
  while the file sat there. Now matches `*.log` and `*log*.txt`, prints the **HEAD** (boot
  banner: version, serial, app version, patch application) as well as the tail, and greps
  for patch/serial/version lines. **Do not narrow this back to `*.log`.**
- **✗ collect snapshots arrived 0-byte** — same exFAT flush bug `finalize_log()` was fixed
  for, in the state-dir copies. Now `sync`s and prints a per-file size, warning on any
  0-byte file instead of reporting success.

**OPEN — the actual question that started this:** with a valid config for the first time,
does `30 FPS++` produce a perceptible latency improvement? Next Deck pass: launch, then
`bash install.sh collect`, and check **`isDevKit:`** in the boot log. `true` = config is
finally live. `false` on a file that now parses = `isDevKitMode` is the wrong key name for
0.16, chase that. NB the user's "55 FPS without latency" reference almost certainly
describes the **60 FPS patch**, not `30 FPS++` — vanilla is a 30 FPS profile by design and
will never feel like 55.

⚠ **Running `install.sh 30` or `35` bare defaults to `DECKBORNE_PROFILE=deckborne`.** For
stage 30 that's harmless today (vblank 60 both). For stage 35 it would **disable
`30 FPS++`** and rewrite the patch set. Pass the profile explicitly when testing vanilla.

**MODS: PROVEN WORKING, then deliberately PARKED (2026-07-18).**

- **✓ The file-overlay pipeline works on-device.** Verified with a GameBanana font mod
  (wingdings) — it applied, showed in game, and reverted cleanly. Stage 40 is sound:
  real backups, `--revert`, layout validation, honest counts.
- **✗✓ THE LOCALE TRAP — this is the one to remember.** The first attempt applied
  perfectly and changed NOTHING in game. Bloodborne keeps per-language copies of menu
  assets and reads exactly ONE, chosen by release region. This dump is **EU GOTY, so it
  reads `menu/enggb`** — but most mods are authored for the US release and ship
  `menu/engus`. Stage 40 replaced a real file the game never opens, and every check
  passed. Found via the emulator's own log:
  `[Kernel.Fs] open: path = /app0/dvdroot_ps4/menu/enggb/font.gfx`.
  **Stage 40 now warns** when a mod writes to `menu/<locale>/` and sibling locale dirs
  exist, and points at that exact log line. When applying any Nexus mod to this Deck,
  check whether it targets engus and mirror it to enggb.
- **`-UPDATE` shadowing did NOT occur** — the update folder does not contain
  `menu/engus/font.gfx`, so no warning fired. The check stays in for other paths.
- **PARKED BY DECISION:** mods need Nexus, Nexus needs an account, and the user has opted
  not to depend on that. `payloads/mods/` is empty again (the font test payload was
  removed after reverting). `config/mods.catalog` stays — it is pointers only (URLs, no
  files) and documents what's compatible for whenever mods come back.
- Consequence: stage 40 is a no-op, so the deckborne profile's **"Apply community mods"**
  UI row promises something that cannot happen. Consider adding it to
  `UI_HIDDEN_STAGES` (like stage 35) until mods are real.

**PLANNED (not started): Nexus integration in the UI.** 2026-07-18 — the user concluded a
good Bloodborne experience probably isn't achievable without mods, so DeckBorne will need
to fetch them. Explicitly NOT immediate. Before designing, know these (all verified):

- **There is no username/password login for third-party tools.** Two mechanisms exist:
  1. **API key** — the user generates one at nexusmods.com → Account Settings → API
     Access and pastes it in. Header `apikey: <key>`, plus REQUIRED `Application-Name`
     and `Application-Version` headers.
  2. **`nxm://` handshake** — the app registers as an XDG protocol handler
     (`MimeType=x-scheme-handler/nxm`), the user clicks "Mod Manager Download" on the mod
     page in a browser, and the browser hands back
     `nxm://<game>/mods/<id>/files/<id>?key=…&expires=…`.
- **Which one you need depends on the user's tier.** `download_link.json` called bare is
  **premium-only** — free accounts get 403 with "this is for premium users only" and MUST
  come through the nxm handshake, because only the website can mint that key. Vortex does
  premium-direct with an nxm fallback; DeckBorne would need the same.
- The user's "log in, then leverage the login to pull from the browser" is essentially
  the nxm flow — the browser session is what authorises the download.
- **ToS constraints:** don't store user API keys server-side; don't ship a personal API
  key in a public app; no bulk/scraping-scale fetching; contact Nexus support once a test
  build exists. Rate limit 20,000/day then 500/hour, per IP.
- Everything downstream already works: a fetched mod lands in `payloads/mods/<id>/` and
  stage 40 applies it (proven on-device). `config/mods.catalog` is where entries live.
- **Remember the locale trap** (above) — a US-authored mod needs mirroring to `enggb`.

**◐ VANILLA PROFILE IS PLAYABLE, NOT FINISHED — locked 30 FPS on-device 2026-07-18.**

⚠ **"Done" here means "good enough to play and to build the deckborne profile from",
NOT solved.** Two things are still wrong and both are worth returning to:
- **Stutters persist.** Not constant, but real. Best current explanation is shader
  compilation (~195 pipelines / ~304 shaders per session, recompiled every launch because
  the pipeline cache is upstream-broken on 0.16 — see PIPELINE_CACHE in deckborne.env).
  That explains FIRST-encounter hitches; if stutter shows up in areas already visited
  this run, the explanation is WRONG and something else is going on. Worth checking.
- **Latency still feels off** even at a locked 30. `30 FPS++` is applied and verified (97
  memory writes in shad_log.txt) but has not delivered a clearly perceptible improvement.
  A better latency fix is the single highest-value thing left for vanilla.
  Leads not yet tried: `present_mode: "Immediate"` (lowest latency, tears — one config
  line); the 60 FPS patch (halves frame time, the most likely real fix, but that is the
  deckborne profile); Steam Input overhead from launching via the Steam tile (never
  measured — try launching the AppImage directly to isolate it); and re-reading
  Bloodborne.xml for anything input/frame related we skipped.
  ⚠ Address-check anything new against the 6 already enabled before adding it.

The whole "it feels laggy" thread resolved here. **The fix was `Resolution Patch 1280x800
(16:10)`.** Bloodborne renders at PS4-native 1920x1080 and was being downscaled to the
Deck's 1280x800 panel — roughly HALF the GPU work thrown away every frame. Enabling the
native-resolution patch produced a locked 30 FPS.

**Do not confuse the two 1280x800 patches — they are independent levers:**
- **Light Grid** keys off the **WINDOW/fullscreen** resolution; lowers lighting draw
  calls. It was applying correctly the whole time and was never the problem.
- **Resolution Patch** keys off the **RENDER** resolution; it is what actually stops the
  game rendering 1080p. This was the missing piece.

**Vanilla's final patch set (6, all verified applying in shad_log.txt):**
`30 FPS++` · `1280x800 Light Grid For SteamDeck (READ NOTES)` ·
`Resolution Patch 1280x800 (16:10)` · `FMOD Crash Fix` · `Unlock Game Region` ·
`Disable HTTP Requests`

**⚠ ALWAYS ADDRESS-CHECK A NEW PATCH BEFORE ADDING IT.** Patches overlap and last-applied
wins, with order set by the XML, not us. Verified conflicts:
- `Performance Patch (perf increase)` — 226 writes; overwrites **BOTH** Light Grid
  addresses (2695cb6, 2695cc0) and shares 5 with `30 FPS++`. **Deliberately excluded.**
  Upstream note confirms it bundles its own 1080p light grid. If ever wanted, it is a
  SWAP for the Light Grid, not an addition.
- The 6 enabled patches share no addresses with each other. Check with a script that
  diffs the `Address` attributes per Metadata block.

**Config companion:** `internal_screen_width/height` are set to 1280x800 alongside the
resolution patch. ⚠ The interaction between the patched render size and shadPS4's
`internal_screen_*` was NOT traced in source — if the image is ever letterboxed/stretched,
revert those to 1280/720 FIRST, before suspecting the patch.

**Next: the deckborne profile.** Template is now proven — copy vanilla's set, swap
`30 FPS++` for `60FPS (no deltatime)` (keep vblank at 60), keep the resolution patch,
and watch the FPS counter for the sub-60 game-speed slowdown its author warns about.
Doing this may ALSO answer vanilla's latency question: if 60 FPS feels right, the problem
was frame time all along and `30 FPS++` was never going to fix it.

**Still remaining (feature work, not blockers):**
1. **Profile differentiation is now REAL for vanilla, still absent for deckborne.**
   Vanilla differs via stage 35 (`30 FPS++`). But `30_apply_config.sh` still does NOT
   branch on the profile, and `PATCHES_DECKBORNE` is empty — so the deckborne button
   currently produces the same result as vanilla minus the 30 FPS++ patch. Tuning the
   deckborne patch set (60 FPS + QOL, watching the sub-60 game-speed tradeoff) is the
   next real behavioural work. Deck-testable only.
   - Also: the deckborne profile shows an **"Apply community mods"** UI row that does
     nothing (payloads/mods is empty and can't be auto-filled). Decide whether to hide
     that row too, or repurpose the stage, when tuning deckborne.
4. **Uninstall has no confirm step** — it's destructive (wipes the ~30 GB install). Add a
   confirm before wiring it in front of real users.
5. Uninstall/collect show a single indeterminate stage (no per-stage markers in
   `99_uninstall.sh`/`90_collect_logs.sh` yet) — cosmetic; add markers there for parity.

**Parked for the GitHub / distribution phase (revisit together):**
- **Desktop shortcut "just works".** `DeckBorne.desktop` only works IN the DeckBorne
  folder (its `Exec` uses `%k`-relative `ui/run.sh`; moved to the Desktop the path breaks,
  and KDE won't run an untrusted `.desktop` anyway). Deferred — a proper fix is an
  install-shortcut step writing an absolute-path entry into
  `~/.local/share/applications/`. Do this as part of distribution, not piecemeal.
- **Move off USB-only distribution.** Endgame the user wants: a `curl | bash` / one-line
  installer so it isn't USB-stick-driven — fetch the pipeline + build/download the UI
  AppImage on-device. Design this when we set up the GitHub repo (the AppImage would be a
  release asset rather than built by each user; the shortcut install rides along).

## TODO — other parked items

1. **Final Steam restart steals the foreground from the installer UI** *(user wants this
   fixed — 2026-07-18; explicitly NOT now, it's a known headache).* The rest of the install
   works great on-device. The one wart: the **last Steam restart** at the end of the install
   brings Steam's window to the FRONT, covering the DeckBorne installer UI. **Desired
   behaviour: the installer stays in the foreground the whole time** — Steam should come back
   *headless / behind the installer / minimized*, never stealing focus.
   - Why it's hard (don't relitigate): the visible restart was the hard-won fix for the whole
     `-silent`→tray→scope saga (see CLAUDE.md "Recently fixed"). On this KDE desktop `-silent`
     goes to a tray icon that never surfaces (read as "Steam never came back"), which is why
     the restart was made visible on purpose.
   - Key lever: **visibility is the FLAGS argument to `steam_start`, independent of the scope
     launch mechanism.** Options to explore next session: raise the installer window back
     on top *after* the restart (KWin/`wmctrl`/`kdotool` activate, or QML `raise()`/
     `requestActivate()` on a timer once Steam settles); OR launch Steam minimized/without
     focus-stealing (KWin window rules, `-silent` only if the tray can be made to surface);
     OR keep Steam visible but immediately re-focus the installer. Any of these must not
     regress the confirmed "Steam survives + portal quiet" behaviour.
2. **Installer progress bar / ETA** — DONE (extraction SUBPROGRESS + ISO readout). This
   old entry is superseded; leave for history.

## What's DONE and verified on-device (don't reopen)

The whole Steam-restart saga is resolved:
- Portal screen-share prompt is gone — Steam launches into its own portal-recognized
  `app-steam-<pid>.scope` via `setsid systemd-run --user --scope` (default, no flag). ✓
- Warm-up runs headless (gamescope) so it can never own the screen. ✓
- `stop_warmup` kills the game by ancestry (not a name pattern) and verifies it died. ✓
- Restarts are VISIBLE (`-silent` went to a tray icon that never surfaces here). ✓
- Steam SURVIVES the script exit — the scope is detached with `setsid` so it gets its own
  session and isn't reaped with the caller's process tree. ✓ (This was the hard one — a
  plain `--scope` died on exit; an interim `--user` service survived but re-opened the
  portal prompt; `setsid` + scope keeps both survival AND portal identity.)
- Uninstall restarts Steam only if it was running, at the end, once. ✓
- Logs `sync` to the USB so they survive a yanked stick / reboot. ✓

## Parked (agreed: one thing at a time)

**Progress bar / ETA for the installer** — design agreed, not started. Plan: source/sink
split. SOURCE = background monitor sampling the extraction dir (`~/Games/shadps4/.extract-tmp`)
vs the known ~30GB total → emits %/ETA (fully testable on the aarch64 dev box with a fake
growing dir). SINK = terminal now, `kdialog --progressbar` popup later (the user is building
a UI installer). Do NOT let a `\r` bar spam the `tee` log — live bar to the terminal, milestone
lines to the log. Build the engine + terminal sink first; wire the popup on a Deck pass.

## Endgame note the user raised

The visible-window restart is a stepping stone. The user ultimately wants Steam to come back
**silently / in the background** (the original idea) so the UI installer doesn't clutter the
screen. That's compatible with whatever launch path wins: `-silent` lives in `steam_start`'s
flags argument, independent of scope-vs-service. When we revisit "quiet Steam," we change the
FLAGS passed, not the launch mechanism. (Right now `-silent` = invisible on this KDE desktop
because the tray icon doesn't surface — making the tray work is a separate SNI investigation.)

## Working logistics (also in CLAUDE.md)

- Dev box is aarch64; the Deck is x86-64. Emulator/extraction/Steam only testable on the Deck.
- Edit in this repo → copy to `/run/media/<user>/RuhRoh/DeckBorne/`. NEVER sync the whole tree
  back (the USB `logs/` are the only copy of on-device runs).
- The user often runs commands on the Deck in Konsole with limited keyboard — keep commands
  short and quote-free.
