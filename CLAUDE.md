# CLAUDE.md — working notes for DeckBorne

Read `README.md` first for what the project *is*. This file is the stuff that isn't
obvious from the code: hard-won facts, traps, and what's left to do.

> **▶ Resuming a session? Jump to [Current state](#current-state--read-this-first-to-resume).**
> It has what just landed, what is open, and the one hazard that needs a decision.

**Map of this file:**

| Section | What it's for |
|---|---|
| [The setup](#the-setup-matters-more-than-it-sounds) | dev box vs Deck, the USB, why the test loop is slow |
| [Steam facts](#steam-facts-all-verified-on-device--do-not-re-theorise-from-first-principles) | verified on-device; believe over any blog post |
| [Code traps](#code-traps) | bugs that bite twice — read before editing a stage |
| [Testing tile behaviour](#testing-tile-behaviour) | the Deck is a contaminated environment; how to test anyway |
| [**Current state**](#current-state--read-this-first-to-resume) | **where we are, what's next, and the open hazard** |
| [Deck hardware facts](#deck-hardware-facts-settled--do-not-re-litigate) | settled limits of this hardware — don't re-litigate |
| [Known bug](#known-bug-the-warm-up-can-lock-you-out-of-the-desktop) | the warm-up lockout, mechanism + fix |
| [What comes next](#what-comes-next-polish-roughly-by-value) | standing backlog |
| [Conventions](#conventions) | how to write code here |

## The setup (matters more than it sounds)

- **The dev box is `aarch64`. The Deck is `x86-64`.** The emulator and the PKG
  extractor **cannot be run here**. Anything about whether the game boots, whether a
  tile appears, or how Steam behaves has to be tested on the Deck.
- **The USB stick is the deployment target, not the source.** Edit files in this repo,
  then copy to `/run/media/<user>/RuhRoh/DeckBorne/`. Never author on the stick.
- **Logs flow the other way.** The USB accumulates run logs written *on the Deck*; the
  repo's `logs/` is a subset. Never sync the whole tree back over the USB — it would
  clobber the only copy of those runs.
- **The test loop is slow and manual**: sync → user carries stick to Deck → runs a
  command → carries it back. Batch changes. Make the installer self-report to the log
  rather than asking the user to run ad-hoc commands — **they often have no keyboard**,
  so prefer short, quote-free commands (`STEAM_TILE_NAME=BBTEST ./install.sh 50`).

## Steam facts (all verified on-device — do not re-theorise from first principles)

These cost several round-trips to establish. Believe them over any blog post.

1. **`LastPlayTime` in `shortcuts.vdf` does not put a tile in Recent Games.** Steam
   ignores it for an appid it has never launched. A tile with `LastPlayTime` stamped
   got a library entry but never a Recent entry.
2. **Only an actual launch does.** Hence the warm-up in `50_steam_shortcut.sh`:
   `steam://rungameid/<gameid>`, wait, kill. Confirmed with a virgin appid at the
   default 15s dwell.
3. **`localconfig.vdf` has no `LastPlayed` for non-Steam games.** Real Steam appids
   have `LastPlayed`; non-Steam ones only ever get `Playtime`/`Playtime2wks`/
   `BadgeData`. Writing `LastPlayed` for a shortcut would be writing a key Steam never
   reads. (A whole implementation was nearly built on this false premise.)
4. **Steam stores a non-Steam game under BOTH appid forms**: `BadgeData` under the
   *unsigned* id, playtime under the *signed* id. Cleanup must remove both.
5. **Steam only reads/writes `localconfig.vdf` and `shortcuts.vdf` at startup/exit.**
   Two consequences: any edit must happen while Steam is stopped (`steam_stop`), and a
   snapshot taken while Steam runs shows its state at the *last shutdown*. Several
   early conclusions were drawn from snapshots that couldn't possibly show the event
   being investigated.
6. **Steam honours the `appid` we write explicitly** into `shortcuts.vdf`, and files
   artwork under it. So the grid appid formula only needs to be self-consistent.
   We hash the **quoted** Exe (`grid_appid()`) to match steam-rom-manager convention.
7. **`xdg-desktop-portal` identifies an app by its systemd scope (cgroup), not its
   binary.** Steam launched as a plain child of the installer stays in the
   *terminal's* scope, so the portal saw it as `konsolerun` and Plasma prompted
   "choose which screen to share with konsolerun" after every install — Steam asks
   for desktop capture (Remote Play) at startup and its restore token
   (`streaming_v2/DesktopCaptureRestoreToken`) only matches under its real identity.
   `steam_start` launches Steam into its own `app-steam-<pid>` unit to fix this. Verify
   with: `grep -o 'app.slice/.*' /proc/<steam-pid>/cgroup`. **NB (2026-07-17):** this
   started as a `--scope`, but a scope runs in the caller's process tree and Steam was
   force-closing the instant the install/uninstall exited. `steam_start` now uses a
   `--user` **service** (`systemd-run --user --collect --unit=app-steam-<pid>`), which is
   owned by the systemd user manager and survives the script — cgroup is now
   `app-steam-<pid>.service`. Same portal identity idea, more robust lifetime.
8. **Steam DOES expand `%command%` for non-Steam shortcuts**, and a shortcut runs as
   `Exe` + `LaunchOptions`. So the *only* way to wrap the launch (gamescope, a debug
   wrapper) while holding `Exe` still — and `Exe` must hold still, `grid_appid()` hashes
   it — is `LaunchOptions="<wrapper> %command% <args>"`. Verified 2026-07-17 by wrapping
   the warm-up and logging argv. What Steam actually runs:
   `steam-launch-wrapper --oom-score-adjust 900 -- reaper SteamLaunch AppId=<appid> --
   <Exe> <LaunchOptions>`. **The AppImage path is in every one of those processes'
   argv** — which is what makes `pkill -f` on it so dangerous (see the known bug).
9. **`gamescope --headless` is gone; it's `--backend headless`.** On the Deck's
   gamescope 3.16.23.2, `--headless -- true` exits 1 and `--backend headless -- true`
   exits 0. Deck session is `wayland` / KDE, so `xdotool` (present) only reaches
   XWayland clients — don't assume it can see shadPS4's window.

## Code traps

- **`die` inside a process substitution kills only the subshell.** `install.sh` builds its
  stage list as `mapfile -t run_list < <(profile_stages)` — a **subshell**. A `die` in
  there exits *that*, `mapfile` reads zero lines, `run_list` comes back EMPTY, the stage
  loop never executes, and **install.sh exits 0 having run NOTHING**. Demonstrated live
  2026-07-19 while adding the chocolate profile: a typo'd profile printed its error and
  still reported a successful install. Profile validation therefore lives in
  `require_known_profile()`, called in the PARENT shell and covering BOTH the full-install
  and single-stage paths, plus an empty-list assertion after the mapfile. The `*)` inside
  `profile_stages` is deliberately **not** a `die` — don't "tidy" it into one.
  Same family as the warm-up bug: a failure a cheerful exit code hides.
- **A `*)` catch-all in a profile `case` silently mis-configures.** Stages 30 and 35 used
  to fall through to deckborne's values for any unknown profile, and report success. Both
  now have explicit cases and `die` on anything unrecognised.

- **`gameid` overflows bash.** `(appid << 32) | 0x02000000` exceeds signed 64-bit;
  `$(( ))` silently wraps it negative. Compute it in Python. (`50_steam_shortcut.sh`.)
- **`localconfig.vdf` is never parsed-and-redumped.** It holds most of the user's Steam
  settings *and live auth tickets*. `purge_play_records()` finds the byte span of the
  entries to delete and splices them out; everything else passes through untouched.
  The parser is quote-aware because Steam stores JSON blobs with escaped quotes and
  braces inside string values — a naive brace matcher corrupts the file.
- **`shortcuts.vdf` appid is stored signed, artwork filenames use unsigned.**
  `signed32()`/`unsigned32()` convert; mixing them up silently breaks artwork.
- **Uninstall matches tiles by `Exe`, not name** (`--by-exe`), so tiles created under a
  throwaway `STEAM_TILE_NAME` still get removed. Name-matching stranded them forever.
- **`.steam/steam` is a symlink to `.local/share/Steam`** on the Deck. Iterating both
  roots hits the same file twice; `realpath | sort -u` collapses them.
- **`find <dir> -maxdepth 1 -iname X` matches `<dir>` ITSELF.** depth 0 is included, so
  "does a `dvdroot_ps4/` exist *inside* `game/dvdroot_ps4/`?" answers YES by self-match.
  In stage 40's resolver that invented a bogus second placement and made it refuse a good
  mod as ambiguous. Use `-mindepth 1`. Latent in the old `_entries_match` for months, only
  because the game root's basename is a title id that never collides.
- **Two ways of spelling one placement are not two placements** (`40_apply_mods.sh`). A mod
  rooted at `dvdroot_ps4/` matches at two different depths that resolve to the SAME
  destination. Ambiguity checks must key on where bytes LAND, not on which candidate pair
  produced the match — otherwise the safe-looking "refuse when ambiguous" rule rejects
  perfectly placeable mods.
- **Extraction is atomic** (`20_install_game.sh`): temp dir, verify `eboot.bin`, then
  swap. An interrupted run cannot corrupt a working install — but it strands ~30GB in
  `~/Games/shadps4/.extract-tmp`.
- **Rewriting a shortcut to change ONE field silently blanks the icon.** Stage 50 writes
  the tile twice on the headless-warm-up path: once WITH `--artwork-dir` (sets the `icon`
  field + installs grid art), then a restore write that swaps launch options back and
  passes NEITHER `--icon` nor `--artwork-dir`. `add_shortcut.py` recomputed
  `icon = args.icon or icon_path_for(...)` → both empty → the restore CLOBBERED the icon to
  "". The grid art (capsule/hero/logo, keyed by filename) still showed, so only the small
  overlay icon broke — it renders as Steam's coloured placeholder box, not "no icon". Fixed
  by inheriting the existing entry's `icon` when updating with none supplied. **Only bites
  the headless path** (the Deck default), which is why the dev box never saw it. Verified
  on-device 2026-07-20. ⚠ Batched with the PNG→ICO change below, so it's UNKNOWN whether the
  field-preserve fix alone (icon still `.png`) would have sufficed — not worth un-batching a
  cosmetic fix that works.
- **`shad_log.txt` holds ONE launch, and `Log.append` in config.json does NOT fix it.** shadPS4
  truncates its log every launch, and stage 50 ends every install by launching the game for
  ~15s — so installing profile B destroys profile A's emulator log *before anyone can collect
  it*. Found 2026-07-25 when three on-device profile switches left evidence for only the last;
  confirmed by counting `Run: Starting shadps4 emulator` lines across eight snapshots — exactly
  one in every file. **`collect` was never at fault**; there was only ever one launch in it.
  ⚠⚠ **The obvious fix does not work, and it fails in the most deceptive way available.**
  Writing `Log.append=true` is accepted, persisted, and *round-tripped by the emulator itself*
  — nine later snapshots all showed `"append": true` in the config shadPS4 wrote back — and the
  log was still truncated, with a later log SMALLER than an earlier one and not a byte-prefix
  of it. The cause is an ordering bug in `src/main.cpp` at v.0.16.0 (revision `5be3f0a3`, the
  exact commit the shipped AppImage reports):
  ```
  107  Common::Log::Setup("shad_log.txt")   <- config not loaded; g_should_append=false
                                               => TRUNCATES the file here
  124  Common::Log::Shutdown()
  126  g_should_append |= EmulatorSettings.IsLogAppend()      <- too late
  127  Common::Log::Setup("shad_log.txt")   <- append mode, but already emptied at 107
  ```
  The **CLI flag** is bound straight to the global (`add_flag("--log-append", g_should_append)`)
  and argv is parsed at line 98, *before* the first Setup — so only the flag can win.
  **Fix: `--log-append` in the tile's LaunchOptions** (`SHADPS4_LOG_APPEND_FLAG`, stage 50).
  `LOG_APPEND` stays too — harmless, and it starts working for free if upstream reorders.
  ⚠ This changes LaunchOptions, so stage 50's `--expect-launch-options` check rebuilds an
  existing tile once. Correct, not a regression.
  ⚠ Once it works, `state-*/shad_log.txt` holds a whole session: **do not assume the file is
  one run** — split on `Run: Starting shadps4 emulator` before attributing patch counts.
  ⚠ Textbook "config.json is not evidence": the key was present and persisted and meant
  nothing. Only the emulator's behaviour settled it.
- **A `config.json` key that only SOME profiles write does not revert — it leaks.** The file is
  MERGED (deliberately: it holds all the user's own emulator settings), so "write it for the
  profile that wants it, omit it elsewhere" means the last profile to write it wins *forever*.
  Found 2026-07-25 the day the desktop target added two desktop-only keys: after installing
  desktop, `GPU.hdr_allowed` was still `true` on a Deck target. Harmless for HDR — **not**
  harmless for `Vulkan.gpu_id`, where a desktop `VULKAN_GPU_ID_DESKTOP=1` surviving a switch
  back to a single-GPU Deck leaves an out-of-range index, and that is a **fatal assert at
  startup**, not a fallback. Both are now written by EVERY profile and target, pinned at the
  emulator's own defaults (`false` / `-1`) and overridden only by desktop. ⚠ The opt-in-keys
  pattern above (`extra_dmem`, empty means "don't write") is only safe because all three
  profiles opt in — it is a latent version of this same bug for any profile added later that
  does not. **Any new per-target key must be written by everyone or it will leak.**
- **`ui_event` must `return 0`, or `set -e` kills the stage silently.** It is
  `[ "$DECKBORNE_UI" = 1 ] && printf …`, whose exit status is **1 whenever the UI is not
  driving** — and every stage script runs `set -euo pipefail`. A top-level `ui_event` call
  in a terminal run therefore exits the stage on the spot, mid-way, with a zero-ish look to
  it. Caught 2026-07-22 within minutes of adding one to stage 20: the run printed its
  progress lines and then simply stopped, never reaching `Game installed — boot target`.
  The pre-existing call inside `_extract_progress` never exposed this only because it runs
  in a background job, where the death is invisible. Fixed at the root (`lib.sh`) rather
  than with `|| true` at each call site, so future callers cannot trip on it.
- **The USB can corrupt source files, and a grep will not tell you.** 2026-07-22: the stick
  suffered exFAT **cross-linked clusters** after being pulled with writes pending —
  `ui/backend.py` held PKG-extractor output (`Extracting file 257 of 29759…`) and
  `steam/add_shortcut.py` held `Main.qml`'s source. **Both kept their ORIGINAL BYTE SIZE and
  mtime**, so `rsync`'s default quick check skipped them: every routine sync reported
  success and could not have repaired it. Use `rsync --checksum` whenever corruption is
  suspected. `build-appimage.sh` then baked the damaged `backend.py` into the AppImage
  (intact to line 420, garbage after) → `SyntaxError: unterminated string literal` at line
  480 on every launch.
  ⚠ **The verification mistake to never repeat:** the rebuilt image was declared good after
  `grep -c '_ERROR'` found its marker. The marker sits *before* the corruption boundary, so
  the grep passed on a file that does not parse. **Grep proves a string is present, not that
  a file is valid — use `py_compile`.** Same family as reaper-vs-game and `pgrep -x steam`.
  `build-appimage.sh` now gates on it: no empty staged files, `compileall -qf`, and a `cmp`
  of every staged file against its source. ⚠ `compileall` **without `-f`** trusts a stale
  `__pycache__` and returns 0 on a broken file — the gate was demonstrated missing the real
  corruption that way. Always `-f`.
  Recovery: `fsck.exfat -r` resolved the cross-links by **zeroing** the disputed files
  (`backend.py`, `Main.qml`, `icon.ico`), which is fine — the repo is the source of truth —
  but it means **copy anything USB-only off the stick BEFORE fscking**. Logs and mods came
  through intact; the nine 0-byte logs it left are the pre-existing 2026-07-17 casualties,
  not fsck damage.
- **`--appimage-version` succeeding does NOT mean the AppImage will run** (`ui/run.sh`).
  The bundled type-2 runtime answers `--appimage-version` *without mounting anything*, so
  the probe passes on a host where the FUSE mount then fails. `run.sh` used that probe as
  its "can I run this?" test and then `exec`'d — which both discards the fallback and, under
  `DeckBorne.desktop`'s `Terminal=false`, discards the error message. Symptom: double-click
  the launcher, nothing happens, no window, no dialog, nothing in any log. Reported
  2026-07-22 straight after an AppImage rebuild, which made the rebuild look guilty — it was
  not: the rebuilt image was verified good (valid x86-64 ELF, correct magic, and its
  squashfs extracted at offset 944632 contained every change of that day). Same family as
  reaper-vs-game and `pgrep -x steam`: **the cheap check proved a different proposition than
  the one being relied on.** `run.sh` now attempts the real run, falls back to
  `APPIMAGE_EXTRACT_AND_RUN=1` (needs no FUSE), then to a staged copy, then to the venv,
  logging each attempt to `logs/ui-launch.log` and raising a kdialog/zenity error if all
  fail. ⚠ To inspect an AppImage off-Deck the squashfs offset is
  `e_shoff + e_shnum*e_shentsize` from `readelf -h` — do NOT trust `grep -abo hsqs`, whose
  first hits are x86 opcodes inside the runtime.
- **Steam's small overlay icon wants `.ico`, not `.png`.** `payloads/artwork/icon.ico` (a
  7-size .ico built from `icon.png`) ships alongside, and `ART_EXTS` now lists `.ico` FIRST
  so `_find_art` prefers it for the icon slot. The library capsule/hero/logo are fine as
  `.png` — only the `icon` field was suspect (EmuDeck's working tiles use `.ico` too). Grid
  art is keyed by filename, so a stale `<appid>_icon.png` from an older install lingers
  harmlessly next to the new `.ico`; the `icon` field points at the `.ico` and wins.

## Testing tile behaviour

The user's Deck is a **contaminated environment**: any appid it has already launched
will show in Recent forever, so it passes tests a fresh Deck would fail. To test
first-run behaviour, use a tile name Steam has never seen:

```bash
STEAM_TILE_NAME=BBTEST9 ./install.sh 50     # fresh name -> fresh appid
```

Check the appid is genuinely unknown first, against a `state-*/localconfig-*.vdf`
snapshot. Don't launch the test tile manually — that contaminates it.

## Current state — read this first to resume

*(This section replaced `HANDOFF.md`, deleted 2026-07-19. That file is still in git
history if you need the long-form UI build saga: `git log --all -- HANDOFF.md`.)*

### ▶ ACTIVE: mod pipeline hardening — the artifacting question is CLOSED

**The pipeline itself is DONE and verified on-device**, front to back: install, extract,
config, patches, mods, Steam tile with artwork, Recent Games, uninstall. The QML/PySide6 UI
in `ui/` has driven a full install *and* uninstall on real hardware, and ships as a
self-contained AppImage (`ui/build-appimage.sh` → `payloads/ui/DeckBorne-<arch>.AppImage`,
~89 MB, gitignored). **Remaining work is tuning and polish, not infrastructure.**

**Three profiles. Two promotions landed 2026-07-19 — the roles have MOVED, do not rely on
an older description of them:**

- **`vanilla`** — the shipping default. **No frame-rate patch**, no mod dependency.
  ✅ **PROVEN ON-DEVICE 2026-07-20** (`logs/deckborne-run-20260720-181624.log` +
  `logs/state-20260720-183329/shad_log.txt`). Both variables that were untested until this
  run are now confirmed FROM THE EMULATOR LOG, not `config.json`:
    - All **7** patches applied at runtime (96 `memory_patcher.cpp:361 Applied patch:` writes),
      no incompat/skip warnings: 1280x800 Light Grid, Resolution Patch 1280x800, Model LOD 1,
      Increased Graphics Heap Sizes, FMOD Crash Fix, Unlock Game Region, Disable HTTP Requests.
    - `memory.cpp:63 SetupMemoryRegions: extraDmemInMbytes is 2000 MB!` — the 2000 value took.
  Game installed, ran, and played. The two ⚠ warnings that used to live here (the 7-patch
  set "has not itself run on-device" and "2000 has NEVER RUN ON-DEVICE") are RESOLVED — do not
  reinstate them. ⚠ Still not literally stock: it keeps Model LOD 1 and FSR upscaling.
  ⚠ The 30-FPS *feel* of this exact config still hasn't been reported (patches applying ≠
  pacing measured) — if anyone plays it, note whether pacing differs from the 2026-07-19 run,
  since vanilla lost `Disable Motion Blur` and dropped dmem 4000→2000 vs that session.
  History of the trim: 2026-07-19 dropped `Skip Intro` and `Disable Motion Blur`; 2026-07-20
  dropped `Disable Chromatic Aberration` and dmem 4000→2000 (vanilla only; deckborne stays
  4000). All are presentation/memory choices, not compatibility fixes.
- **`deckborne`** — the tuned experience: vanilla + `30 FPS++`, the three presentation
  patches vanilla dropped, `extra_dmem=4000`, **and a HARD MOD DEPENDENCY** (below). No
  longer frozen — it was promoted, deliberately. ⚠ It is no longer a strict superset of
  vanilla's *settings*, only of its patches — the dmem values differ.
- **`chocolate`** — the DEV/STAGING lane. Its patch set is **identical to deckborne** again,
  so it is a free experiment slot. One thing now differs: it is the only profile that keeps
  the on-screen FPS counter (below).

**Changed 2026-07-23:**

1. **The on-screen FPS counter is now PER-PROFILE, and OFF for vanilla and deckborne.** It
   was one global (`DECKBORNE_SHOW_FPS`) all three profiles shared; there are now
   `SHOW_FPS_VANILLA` / `_DECKBORNE` (false) and `SHOW_FPS_CHOCOLATE` (true), selected in
   stage 30's `case`. Rationale: the two shipping profiles are what a user installs to
   *play*, and a permanent counter is a debug overlay; chocolate is the measuring rig and
   keeps it. ⚠ **Consequence:** the profiles a user actually runs no longer carry a frame
   instrument, so "it feels worse" can't be checked against anything — re-run the
   comparison on chocolate, or `SHOW_FPS_DECKBORNE=true ./install.sh 30` for one run.
   Stage 30 logs the effective value on its `Profile '<name>' →` line.
2. **`60 FPS++` RAN ON-DEVICE — two results, and they are not the same result.** deckborne
   ran it for a full install + play session, then went back to `30 FPS++`.
   - **Rendering: CLEAN.** With the vertex-explosion mod applied there were **no face/cloth
     explosions**. ✅ The pairing the notes called UNVERIFIED is now **VERIFIED** — the
     "FPS++ family requires the mod" rule holds for both members, and the mod fully covers
     60 as well as 30. Evidence: 192 `60 FPS++` writes (matches the 2026-07-18 count, so
     the upstream XML is unchanged), dmem 4000, vblank 60, 530 reads under
     `dvdroot_ps4/parts/`, no `-UPDATE` shadow warning.
   - **Performance: not feasible on a standard Deck.** That — not artifacting — is why it
     reverted. A hardware ceiling, not a correctness problem.
   ⚠ Do not re-litigate this as "60 FPS++ is broken". It works; the Deck just can't feed
   it. Which is exactly what makes it the basis for the desktop profile below.

`chocolate` is CLI-only; `ui/backend.py` offers only vanilla and deckborne, deliberately.

### ▶ NEW 2026-07-25: deckborne is THREE experiences, chosen in the UI

The user picks frame rate + resolution on the DeckBorne card itself. **`DECKBORNE_TARGET`
carries the choice**: `deck30` (30 FPS · 800p, default), `deck60` (60 FPS · 800p),
`desktop` (60 FPS · 1080p).

**A TARGET, NOT A FOURTH PROFILE — and that distinction is load-bearing.** All three run the
*identical stage list*, which is what keeps install.sh's `@@DBUI STAGE <idx>` markers aligned
with `STAGES_DECKBORNE` in `ui/backend.py`. A profile would have to be wired into
`profile_stages`, both stage `case`s, `require_known_profile` AND a new UI stage array; a
target only changes values. ⚠ Do not "promote" a target to a profile without re-checking that
alignment — it is the same index-shift trap as the mods row.

- **`deck30` is byte-identical to what deckborne shipped before**, and is the default when
  nothing sets the variable, so an unchanged run is unchanged.
- **Only stage 30 and stage 35 read it**: 35 picks the patch string; 30 picks the
  window/internal resolution, `extra_dmem`, `fsr_enabled` and `Vulkan.gpu_id`. vblank is
  deliberately NOT switched — the pairing rule gives both `++` variants 60 Hz.
- **Validated in three places** (`require_known_target` in install.sh, plus explicit `die`s in
  both stages) because a single-stage run bypasses install.sh's check entirely. A target set
  on a profile that ignores it *warns* rather than passing silently.

⚠ **1080p is NOT a frame-rate flag, and this is the thing to remember.** Two of the enabled
patches are resolution-keyed, so the desktop target swaps *both*:
`1280x800 Light Grid` → `1080p Light Grid`, and `Resolution Patch 1280x800 (16:10)` →
**`Optimal 1080p`**.

⚠ **THERE IS NO `Resolution Patch 1920x1080` UPSTREAM.** Verified 2026-07-25 against the live
XML (59 patches): the 16:9 ladder runs 640x360, 960x540, 1280x720, 1440x810, 1600x900,
2560x1440, 3840x2160 — it **skips 1080p entirely**. `Optimal 1080p` is the only 1080p render
patch and it is a *different kind* of patch: its note is "360p global with main renders at
1080p", and unlike the 1280x800 one it makes no claim about moving lock-on / HP-bar
coordinates. Don't go looking for the 1920x1080 entry again; it isn't there.

⚠ **The desktop target has NEVER RUN ON ANY HARDWARE.** Names and additivity are verified,
appearance is not.

**It diverges from `deck60` in five places (2026-07-25), each one un-inverting a Deck
compromise rather than inventing something new:** resolution (1080p), `Model LOD -2 (Highest)`
instead of `LOD 1 (Lower)`, `extra_dmem` 6000 (the value the source post actually used),
`fsr_enabled=false` (the post disabled FSR on an RX 6800; a Deck needs it, a desktop rendering
natively does not), and an explicit `Vulkan.gpu_id`.
- ⚠ **The two LOD patches write the SAME address** (`0x0216fc09`) — a straight swap, never both.
- ⚠ **`Disable Motion Blur` and `Disable Chromatic Aberration` STAY** — the user's call
  2026-07-25: they are QOL for Bloodborne on PC, not Deck performance cuts. Don't "restore"
  them for desktop on the reasoning that a desktop can afford them.

⚠⚠ **`Vulkan.gpu_id` — DO NOT "IMPROVE" THIS INTO AUTO-DETECTION. The emulator already does
it, better.** The obvious-looking task ("detect the strongest GPU at install time and write the
index") is *worse than doing nothing*, and this was only caught by reading
`vk_instance.cpp` v0.16.0:
- With `gpu_id < 0`, shadPS4 sorts every physical device by **(1) supports Vulkan 1.3,
  (2) is DISCRETE_GPU, (3) largest device-local heap** and takes the winner. That *is* "pick the
  strongest GPU", decided from real Vulkan properties we cannot see from outside.
- With `gpu_id >= 0` it skips all of that and indexes raw `vkEnumeratePhysicalDevices` order —
  and an out-of-range index hits `ASSERT_MSG` → `assert_fail_impl()`, which is **not** compiled
  out in release. A wrong number is a hard startup failure, not a graceful fallback.
- The Reddit post's "select your strongest GPU" advice predates this (0.13/0.14, Qt GUI).
So the target writes **-1 explicitly** — auto, but deterministic, resetting a user who had
experimented with an index. `scripts/detect_gpu.py` **reports** (never decides): it parses
`vulkaninfo --summary`, replicates enough of the sort to name the device shadPS4 will land on,
falls back to `lspci` labelled as *not* Vulkan order, and returns -1 rather than guessing when
two devices tie on everything `--summary` exposes (it has no heap sizes). Stage 30 prints it
into the run log for this target. Verified with 18 synthetic-device checks, including the
ordering trap that **Vulkan 1.3 support outranks discrete-ness**, so a modern iGPU legitimately
beats an old discrete card.

**Verified 2026-07-25 against the LIVE upstream XML — all three sets clash-checked pairwise,
no shared addresses in any of them.** Write counts, for comparing against `memory_patcher` in
`shad_log.txt`: `deck30` 30 FPS++ 97 / Resolution 82 / Light Grid 2 · `deck60` 60 FPS++ 192 /
Resolution 82 / Light Grid 2 · `desktop` 60 FPS++ 192 / Optimal 1080p 76 / Light Grid 2.

**UI (`Main.qml`):** `OptionCard` gained a `footer` Component slot. **A card with a footer set
is no longer clickable** (`actionable` is derived from it) — the three `FpsPill`s are what
start a run. It also gained `tapOpen`, because the card must still be *reachable*: Game Mode
has no hover at all, so on a touchscreen the header now toggles the card open instead of
launching. Vanilla and Uninstall are unchanged and still launch on click.

**`GPU.hdr_allowed` — PER-PROFILE (user's call 2026-07-25): `true` for deckborne (all three
targets) and chocolate, `false` for vanilla.** Vanilla means the game as it shipped, and
Bloodborne shipped in 2015 without HDR — permitting an output mode the original never had is
exactly the kind of small reasonable addition that erodes what vanilla means, same reasoning
that keeps the FPS counter and the frame-rate patches out of it. Set knowing it is inert for
the stock game either way. Two facts make enabling it safe rather than optimistic:
- It is a **permission, not a command**. `vk_swapchain.cpp:162-167` ANDs it with a real
  capability query — the driver must advertise Rec.2020 PQ — so on a non-HDR display it is
  ignored and the normal SDR swapchain is used. There is no failure mode where it breaks a
  monitor.
- **Bloodborne is a 2015 title predating PS4 HDR**, so it never requests HDR output and
  `Swapchain::SetHDR` never fires. The reason it is on is that a MOD adding HDR output would
  otherwise be blocked by an emulator setting the user has no reason to know about.

⚠ Do not read this as "HDR works on Bloodborne". ⚠ You cannot confirm it from a run log either
— unlike present_mode (which warns when the driver refuses), HDR only appears at `LOG_DEBUG`.
NB the Steam Deck OLED *is* HDR-capable, so this is not automatically a no-op on a Deck the way
the other desktop-only settings are; it is moot only because the game never asks.

⚠ **vanilla writes `false`, it does not omit the key** — that is the leak rule below, in the
direction that matters: if vanilla merely skipped it, a deckborne → vanilla switch would leave
HDR permitted in the one profile whose whole premise is the stock game.

⚠ **All three targets are FPS++ family, so ALL THREE carry the mod dependency** — the open
hazard below now applies to every DeckBorne install, not just one config.

**Verified off-Deck 2026-07-25**, both halves, and the pipeline half genuinely end-to-end
(stage 35 really fetched the XML and really wrote patch files into throwaway dirs):
- **QML, 21 checks** against a real offscreen render (`qtvenv` + `main.py --shot`): three
  pills present and labelled, each starting the right target with the right headline, the
  DeckBorne card `actionable === false` while Vanilla/Uninstall stay true, tap-to-expand
  working, pills gated on `storageReady`, and the stage-row count still **6** for every target.
- **Pipeline:** resolution follows the target (800p/800p/1080p), vanilla ignores it, deck30 and
  deck60 differ by *exactly* the FPS patch and nothing else, desktop swaps both resolution-keyed
  patches, all three enable 11, vanilla still 7, an unset variable is identical to `deck30`, and
  a bad value dies in install.sh *and* in each stage run standalone.
- **Switching, 57 checks** over one shared `config.json` + patches dir, the way a real Deck
  has it: `deck30 → deck60 → desktop → deck30 → vanilla → desktop`, asserting after every hop.
  This is the suite that caught the leak. It also proves the switch story end to end — the
  enabled patch set flips completely with no residue, resolution follows both ways, dmem/FSR
  track the profile, the user's own emulator settings survive every hop, and a repeat of the
  same target is a genuine no-op.
- **GPU, 18 checks** against synthetic `vulkaninfo` output (this box has neither vulkaninfo
  nor lspci, so the parser had to be tested against fixtures).

**Totals: 118 checks, four suites, all green.** Re-run them from
`/tmp/.../scratchpad/{gpu,qml}_probe.py` + `{pipeline,switch}_probe.sh` if they still exist;
they are throwaway, so rewrite rather than trust a stale copy.

⚠ Needs an **AppImage rebuild on the Deck** to be visible, like every `ui/` change.

**Ready for on-device testing. Nothing in this feature is half-finished** — the two deferred
bugs below (UI cancel, the `game-pkg/` requirement) are pre-existing and were benched
deliberately for this release's bug-squash pass, not left broken by this work.

### ▶ NEW 2026-07-24: the install location is selectable (SD card / USB support)

**Verified off-Deck only — nothing here has run on a Deck with a real SD card.** The
detection, validation, persistence and uninstall paths were all exercised on the dev box
(which happens to carry an exFAT USB drive, so the reject path is genuinely tested); the
happy path on an ext4 SD card is untested because this box has none.

**Only `GAMES_DIR` moves. `APP_DIR` deliberately stays in `$HOME`, and that is
load-bearing** — the Steam tile's `Exe` is `$APP_DIR/$SHADPS4_APPIMAGE_NAME` and
`grid_appid()` hashes the quoted Exe (Steam fact 6). Moving APP_DIR would change the
appid, so a tile made while the card was in would become invisible to the uninstaller's
`--by-exe` match the moment the storage choice changed — stranded in the library forever.
It is also ~100MB against the game's 30GB. Do not "tidy" this into moving both.

- **`scripts/detect_storage.py`** is the single source of truth. `--json` (UI),
  `--check <root>` (stage 00, exit code + one user-facing line on stderr), `--human` (run
  log + `collect`). It parses `/proc/self/mountinfo`, offers `$HOME` plus anything under
  `/run/media` / `/media` / `/mnt` on a real block device.
- **It lives in `scripts/`, NOT in `ui/`, on purpose.** The AppImage bundles `ui/` only
  and resolves the pipeline at runtime, so detection can be fixed by editing the USB —
  no AppImage rebuild, which would have to happen on the Deck.
- **exFAT/NTFS/vfat are REFUSED, not warned about.** They are case-insensitive, and both
  the game's asset lookups and stage 40's "does this path already exist?" resolver answer
  differently there. SteamOS formats SD cards ext4, so the good path is the normal path.
  The device is still LISTED, dimmed, with the reason and the Format-SD-Card instruction —
  hiding it leaves the user hunting for a card that is plugged in.
- **Resolution order is env > remembered > `$HOME`** (`config/deckborne.env`). Default is
  `$HOME`, so `GAMES_DIR` is byte-identical to every pre-feature install — nothing migrates.
- **The choice is PERSISTED** to `$HOME/.local/share/DeckBorne/storage_root` by stage 00
  once validated, because `install.sh 50` a week later and `install.sh uninstall` must both
  still find the game. Kept in `$HOME` so it is readable with the card out.
- **A remembered root is NEVER existence-checked at load time**, deliberately. If the card
  is out, the right answer is to keep pointing at it — so the uninstall still works once it
  is back, and so stage 00 can say "is it still plugged in?" instead of silently falling
  back to `$HOME` and re-extracting 30GB onto the wrong device.

⚠ **Three traps found while building this — all the same family as the ones above:**

- **`die` inside `$(command substitution)` is the process-substitution trap again.** The
  first cut of `require_boot_target` returned the path on stdout, so callers wrote
  `t="$(require_boot_target)"` — a SUBSHELL, where `die` exits only that subshell and the
  stage carries on with an empty path. It sets a global (`BOOT_TARGET`) instead. Never give
  a `die`-ing helper a stdout return value.
- **Stages 40 and 50 checked the boot-target MARKER, not the game.** `.boot_target` lives in
  `$APP_DIR` (i.e. `$HOME`), so it survives the card being pulled while the game it names
  does not — stage 50 would build a tile pointing at nothing and stage 40's revert would
  report "already stock" about a game it cannot see. `require_boot_target` now verifies the
  target file and gives a storage-aware message.
- **The uninstall nearly forgot the record at exactly the wrong moment.** "Forget the
  remembered root once the game is gone" tested `[ ! -d "$GAMES_DIR" ]` — which is also true
  when the device is simply unmounted, i.e. when that record is the only thing that can still
  find those 30GB. It now requires `[ -d "$DECKBORNE_STORAGE_ROOT" ]` too, and an uninstall
  against an unmounted device warns that the game was NOT removed rather than reporting a
  clean sweep.

**Switching devices MOVES the install instead of re-extracting (2026-07-24).** A user who
installed to the internal drive and then picks the SD card would otherwise pay ~20 minutes
to unpack a game that already exists. Stage 00 detects it and announces the plan; stage 20
performs it (that is where the progress plumbing and the extract-or-skip decision already
live). `DECKBORNE_NO_RELOCATE=1` forces a fresh extract.

- **Copying beats extracting for a reason beyond speed: it carries the mod state.**
  `<title>.pre-mods` holds the ORIGINAL extraction's bytes, which is the invariant that
  makes repeated profile switching safe. A re-extract would produce stock files with no
  backup, silently stranding a modded game as "stock". The move takes `<title>`,
  `<title>-UPDATE` and `<title>.pre-mods` — **never the whole games dir**, which may hold
  other titles the user installed with shadPS4 themselves.
- **Copy → verify → swap → only then delete the source.** Verification is eboot.bin
  present plus file-count AND total-bytes match. ⚠ It counts **regular files only** —
  directory `st_size` is filesystem-dependent, so including directories made a perfectly
  good cross-device copy fail verification. Same-filesystem moves skip all of this and
  just `mv` (instant).
- **Refuses to guess.** Installed on two candidate roots → warn and extract fresh rather
  than pick one. A copy already at the destination always wins over one elsewhere.
- **`@@DBUI STATUS <text>`** is a new marker that overrides the current stage's friendly
  message and clears the quote panel, because stage 20's row says "Extract Bloodborne"
  and a relocation is not an extraction.

⚠ **Two more traps, both found by actually interrupting a real copy — this is why the
mid-flight test was worth doing rather than reasoning about it:**

- **A cleanup trap on INT/TERM MUST `exit`.** Bash *resumes the script* after a handler
  that doesn't, so the pre-existing `trap _sweep_extract_tmp EXIT INT TERM` swept the temp
  dir and then carried on writing into the directory it had just deleted. Tolerable for an
  extract; intolerable for a path that goes on to DELETE THE SOURCE. Now `trap _sweep_all
  EXIT` + `trap _on_signal INT TERM`, the latter exiting 130.
- **Ctrl+C orphaned the `cp`.** The script died, the copy did not — it recreated the temp
  dir the sweep had just removed and kept writing gigabytes to the card with nothing
  attached. Observed directly: the swept directory came back. `_stop_workers` now TERMs the
  worker **by pid** (never `pkill -f` — that matches the shell issuing it) *before*
  sweeping. Applies to the extractor too, which had the same orphan behaviour.

Verified off-Deck: cross-device move with full sha256 manifest comparison (40k files,
identical), mod backups carried, source removed, boot target updated, same-device rename
fast path, idempotent re-run, both refusal branches, and a mid-copy SIGINT leaving the
source byte-identical with the temp swept, no orphaned `cp`, and no half-install at the
destination.

### ✅ PROVEN ON-DEVICE 2026-07-24 — and it found two real bugs

Three real Deck runs (`logs/deckborne-run-20260724-135454`, `-141015`, `-141123`), all
completing with **no errors**, exercising every branch: internal→SD (relocate), SD→SD
(skip, "already installed at the chosen location"), SD→internal (relocate back). Profiles
switched across the moves too (vanilla → deckborne → deckborne), and stage 40 reconciled
correctly each time, including `Restored 5 update-folder file(s) the shadow mirror had
replaced` — so the `-UPDATE` mirror survives relocation.

- **30GB moved in ~14 min internal→SD, ~6 min SD→internal**, versus ~20 min to re-extract.
  Copy verified both ways (29561 files / 30.0G, then 29603 / 29.9G — the delta is mods
  added between runs), old copy removed, boot target rewritten.

⚠⚠ **BUG FOUND AND FIXED: relocation left the Steam tile pointing at the OLD path.**
Stage 50's skip check asked only "does a tile + artwork exist for this Exe?" — which was
sufficient while the boot target was immutable, and became wrong the moment relocation
could move it. The 14:10 collect is the proof: game on the SD card, tile still reading
`-g "/home/deck/Games/shadps4/CUSA03173/eboot.bin"`, a path the move had just deleted.
**The tile launched nothing**, and nothing in the run said so — it cheerfully logged
"Steam tile and artwork already installed — skipping". It only looked fine at the end of
the session because the third run happened to move the game back to where the tile pointed.
Fixed with `add_shortcut.py --exists --expect-launch-options <str>`: the skip now also
requires the stored LaunchOptions to match what stage 50 would write, so a relocated
install rebuilds the tile. `launch_options` had to move ABOVE the skip check to do it.
Verified against a synthetic `shortcuts.vdf` reproducing the user's real tile (same appid,
3941800555): same-path → skip, relocated → rebuild, relocated-back → skip, artwork lost →
repair, and no `--expect-launch-options` → old behaviour unchanged.

⚠⚠ **BUG FOUND AND FIXED 2026-07-24: two `steam_start` calls in one run COLLIDED, and
stage 50 died.** `logs/deckborne-run-20260724-143835.log` — a fresh install did all of
stage 50's real work (tile written, artwork installed, warm-up launched and cleanly
stopped, tile restored) and then failed at the final restart with
`steam=[] webhelper=[] app-steam scopes=[]`.

Cause: `steam_start` named the scope `app-steam-$$`, and `$$` is the STAGE's pid —
**constant** — while stage 50 calls it TWICE: the `-silent` restart that drives the
warm-up, then `steam_restart_visible` at the end. The second `systemd-run --unit=` hits
`Failed to start transient scope unit: Unit app-steam-<pid>.scope was already loaded or
has a fragment file` (reproduced locally, verbatim). The launch is backgrounded with
stderr to `/dev/null`, so **the failure was invisible** — the run could only report
"Steam may not have come back up".

⚠ **Why it stayed hidden until now:** every previous run either had no tile yet (one
`steam_start`) or SKIPPED stage 50 entirely ("already installed"). It took the
`--expect-launch-options` fix above — which correctly makes a relocated install rebuild
the tile — to produce a run that calls `steam_start` twice. One fix exposed the next.

Fixed two ways, both needed:
- **Unique unit per call:** `app-steam-$(date +%s%N)`. ⚠ Keep the shape
  `app-steam-<ONE dash-segment>` — the portal reads the app-id from between the first and
  last dash, so `app-steam-<pid>-<n>` would yield app-id `steam-<pid>` and lose the portal
  identity that whole branch exists for (Steam fact 7). Verified: two calls in one shell
  now create two live scopes; the old naming produced one scope and one silent failure.
- **Capture the stderr** (`STEAM_START_ERRLOG`) and print it in the failure diagnostic
  along with the requested unit name. Same lesson as reaper-vs-game and `pgrep -x steam`:
  the code knew why it failed and threw the reason away.

⚠ **BUG FOUND AND FIXED: an unlabelled SD card displayed as its UUID.** SteamOS mounts a
labelled volume at `/run/media/<user>/<label>` but an unlabelled one at its UUID, so the
picker read `SD card (90f57fcc-c7de-4fa8-a9a0-383119895204)`. `_mountpoint_label()` now
returns "" for a UUID-shaped basename and the name falls back to a bare `SD card`.

### ⚠⚠ OPEN BUG — deferred 2026-07-24: the UI Cancel button does not stop a relocation

**Not yet fixed — the session it surfaced in was scoped to the storage feature. Fix next.**
The relocation code (`relocate_install` in `20_install_game.sh`) is itself correct:
copy → verify → swap → delete-source, with a `trap _on_signal INT TERM` that kills the copy
worker by pid and sweeps `.move-tmp`. The trap works — **when the signal reaches the stage.**
The UI's cancel never delivers it there.

**Mechanism (traced end-to-end with a deterministic slow copy, 2026-07-24):**
`backend.py::cancel` calls `QProcess.terminate()` → SIGTERM to `install.sh`'s **pid only**
(Qt sends to the single child pid, not the process group), waits 2000ms, then
`QProcess.kill()` → SIGKILL to that same pid. But `cp` runs three levels below:
`install.sh` → the `main | tee` subshell → `bash 20_install_game.sh` → `cp`. A single-pid
signal to `install.sh` never reaches the stage where the cleanup trap lives, and
`install.sh`'s own TERM trap is deferred while it waits on the foreground `main | tee`
pipeline. After 2s the SIGKILL kills `install.sh`; the subshell, stage and `cp` are **not**
signalled — they orphan and keep running. The orphaned stage runs the copy to completion,
then completes the swap and **deletes the source** — 18s *after* the user clicked Cancel in
the reproduction. Trace: `CP-DONE` and `SOURCE-DELETED` both stamped 18s post-cancel.

**Consequences (none is data loss, but all are wrong):**
- Cancel is a no-op on a slow target (the SD case — a fast tmpfs copy that finishes inside
  the 2s window happens to look clean, which is why the first cancel test misled). The 30GB
  move completes in the background while the UI shows "Cancelled".
- The install ends up *moved but half-configured*: stages 30/35/40/50 never ran, because the
  UI believed it cancelled.
- Real hazard: a user who clicks Cancel and then acts on it — pulls the card / powers off —
  interrupts the still-running orphaned copy. Source survives (deleted only post-verify), but
  a partial `.move-tmp` is stranded (swept on the next stage-20 run) and no install completes.

**Not broken from a terminal:** Ctrl-C signals the whole foreground process GROUP, which
includes the stage, so the trap fires and it cleans up correctly. It is specifically the UI's
single-pid `QProcess.terminate()/kill()` path that misses.

**Fix (next session), contained to the UI cancel path:** signal the process GROUP, not the
pid — start `install.sh` via `setsid`/its own group and have `backend.py` send SIGTERM (then
SIGKILL) to the negative group id; OR give `install.sh` a TERM trap that tears down its stage
subtree. Either makes UI-cancel behave like Ctrl-C. ⚠ Whatever the fix, RE-TEST with a
genuinely slow copy (throttle, or a real SD card) — a tmpfs copy finishes too fast to exercise
the orphan path and will pass a broken implementation.

### ⚠ OPEN BUG — deferred 2026-07-24: relocation still requires `game-pkg/`, and it shouldn't

**Not yet fixed — logged mid storage-session for a later pass.** The `.pkg` dump is a hard,
unconditional requirement: `00_preflight.sh:28` and `20_install_game.sh:19` both
`die` on `discover_base_pkg` returning empty. That is correct for a FRESH install (you can't
extract a game you don't have) — but a **relocation reads zero bytes of the `.pkg`**. It copies
the already-extracted `<title_id>` / `-UPDATE` / `.pre-mods` folders from one device to another.
So a user who extracted the game, deleted the bulky `.pkg` off the USB to reclaim space, then
wants to move the install to the SD card is blocked for no functional reason.

**The only thing the `.pkg` provides on that path is `title_id`** (`pkg_title_id "$base_pkg"`,
falling back to `$GAME_TITLE_ID`). For an already-installed game the title-id is already
available three other ways: the `.boot_target` marker
(`basename "$(dirname "$(cat $APP_DIR/.boot_target)")"` — exactly what stages 35/40 already
do), the existing `$GAMES_DIR/<title>` dir name, or `detect_storage.py --find-install`. The
`update_pkg` lookup is only used by the extract path and the `game_already_extracted`
completeness check — a relocation doesn't need it either.

⚠ **Broader than relocation:** the same unconditional `discover_base_pkg` die means a plain
**profile switch on an already-extracted install** (the "game already extracted — skipping"
path) ALSO demands `game-pkg/` still be present, even though it re-extracts nothing. Same root
cause, same fix.

**Fix direction (next session):** derive `title_id` from the installed game / `.boot_target`
FIRST, and only fall back to `discover_base_pkg` when nothing is installed yet. Make the
preflight and stage-20 `.pkg` requirement conditional on "no complete extraction exists
anywhere" rather than absolute. ⚠ Keep the fresh-install failure intact: no install AND no
`.pkg` must still `die` loudly.

UI: an inline `Install to: <device> ⌄` control sitting **beside "Collect logs"**, opening a
hover dropdown of devices. ⚠ **The first cut of this was a full-width "INSTALL LOCATION"
section of device rows above the three cards, and it was rejected on sight (2026-07-24) —
it buried the three option cards, needed a Flickable to stop overflowing at three devices,
and made the home view look like a settings page.** Do not reintroduce it. The home view
keeps its original shape: three cards, then one bottom row.
- Closes on a **220ms delay**, not immediately — a gap between button and list would
  otherwise close the menu as the pointer crossed it.
- **Tap toggles it as well as hover.** The Deck is a touchscreen and Game Mode has no hover
  at all, so a hover-only menu would be unreachable there.
- **Defaults to the root filesystem**, per the user's explicit ask — overridden ONLY by a
  device that already holds the game, so merely opening the window never proposes moving
  ~30GB off an SD card. Unusable devices are listed dimmed and are not selectable.
- `--open 9` forces the dropdown down for screenshots, reusing OptionCard's `previewOpen`.

Install buttons are disabled while no usable device is selected. **Only the INSTALL path passes
`DECKBORNE_STORAGE_ROOT`** — uninstall and collect must act on where the game actually IS
(the recorded root), or a user who swapped cards could "uninstall" a device that never held
it and be told it worked. If `detect_storage.py` is missing (new AppImage, old USB) the
backend falls back to a single `$HOME` entry rather than blocking every install.
⚠ **Needs an AppImage rebuild ON THE DECK to be visible** — same constraint as every other
`ui/` change.

### ▶▶ RESOLVED 2026-07-19: the artifacting was `30 FPS++`, and the mod fixes it

Two single-variable runs settled it, in this order:

1. **Dropping `30 FPS++` made the artifacting GO AWAY** (Model LOD 1 still enabled
   throughout). So the FPS++ family IS the cause — and `Model LOD 1 (Lower)` is
   **EXONERATED**, present in both the broken and clean states. The follow-up run once
   reserved for it is unnecessary. `fsr_enabled`, `extra_dmem=4000` and `Increased Graphics
   Heap Sizes` all ran through the clean session too, so none of them artifact alone.
   That clean config was promoted to **vanilla**.
2. **`30 FPS++` + the Nexus vertex-explosion fix = CLEAN.** Chocolate ran the full 11-patch
   set with the mod applied and the artifacting did not return. That config was promoted to
   **deckborne**.

**Evidence for run 2 came from `shad_log.txt`, not `config.json`** — the project rule.
Keep these, they are what make the result trustworthy rather than anecdotal:

- `memory_patcher.cpp:361 Applied patch: 30 FPS++` at **5 offsets** — live in memory, not
  merely requested. Without this the clean result would just be describing vanilla.
- stage 40: `placing at: dvdroot_ps4/ (matched on existing files)`, **144 files replaced**.
- **the `-UPDATE` shadow warning never fired**, so the modded BASE files are the ones the
  emulator serves. This was the top risk — a shadowed mod reads exactly like a mod that
  does not work.
- **454** `/app0/dvdroot_ps4/parts/…` opens — the game genuinely read them.
- `memory.cpp:63 SetupMemoryRegions: extraDmemInMbytes is 4000 MB!`

⚠ **The control was SKIPPED.** "Chocolate WITHOUT the mod must still artifact" was never
re-run on this fresh install, so strictly the reinstall is an uncontrolled variable. Run 1
already established causation, so this is confirmation rather than discovery — but if
anything downstream looks wrong, that is the untested link. Cheap to close:
`scripts/40_apply_mods.sh --revert`, play, confirm it returns, re-apply.

### ⚠⚠ THE OPEN HAZARD: deckborne ships a config that NEEDS a mod we cannot ship

`30 FPS++` is safe in deckborne **only because** the vertex fix is layered over it by stage
40. DeckBorne must not redistribute that mod (`config/mods.catalog` explains why), so:

> A user who picks **DeckBorne** with an empty `payloads/mods/` gets an FPS++ patch with no
> fix and **WILL** see vertex explosions.

⚠ **Widened 2026-07-25:** this used to be about `30 FPS++` alone. All three `DECKBORNE_TARGET`
values are FPS++ family, so **every** DeckBorne install now carries the dependency — there is
no longer a target a user could pick to avoid it.

Nothing blocks that combination today. Stage 40 warns when it finds no mods, and the UI row
says "Community mods (none installed)" — right before the game renders wrong. **This is the
most user-facing unfinished thing in the repo.** Options weighed, none chosen yet: hard-warn
in stage 40 when profile is deckborne and no mods are present; explain the requirement on
the DeckBorne button in the UI; or gate `30 FPS++` on the mod actually having been applied.

### Mods: PROVEN and IN USE — no longer "parked"

The old "mods are parked pending a Nexus account" note is **obsolete**. The user supplies
mods manually and the pipeline applies them. Three are in the repo's `payloads/mods/`:
`vertex-explosion-fix`, `MOAL-…`, `SFXR 60fps Cutscene Fix…`.

⚠ **The repo and the USB stick DIFFER, and not by one mod — verified 2026-07-22.** They
now share only `vertex-explosion-fix`; the other two on each side are different mods
entirely. **Exclude `payloads/mods/` when syncing** unless told otherwise — a plain
`payloads/` rsync would overwrite the stick's set with the repo's and silently change what
stage 40 applies.

| | repo `payloads/mods/` | USB `payloads/mods/` |
|---|---|---|
| shared | `vertex-explosion-fix` | `vertex-explosion-fix` |
| | `MOAL-107-…` | `01 - 16x10-207-…` |
| | `SFXR 60fps Cutscene Fix…` | `Elden Ring Style - Modern Xbox prompts-30-…` |

⚠ The old claim here — "the stick holds only `vertex-explosion-fix`, so the mod ladder
stays single-variable" — is **FALSE as of 2026-07-22**. The stick carries three. deckborne
is still safe there (the vertex fix is present, so the `30 FPS++` dependency is met), but
any run off this stick has two extra presentation mods in it, so it is **not** the clean
single-variable baseline the old note promised. Do not attribute a visual change to the
profile without checking stage 40's applied list in the run log first.

**Stage 40 now resolves mod layout automatically** (2026-07-19). The user unzips a mod and
drops the folder in **as-is**; the resolver searches both unknowns — nesting depth and which
game directory the tree anchors to — and lets the installed game arbitrate by asking "do
these files already exist under you?". Handles game-root-relative, dvdroot-relative
("modloader friendly"), and arbitrarily nested wrappers. It refuses, loudly, on multi-variant
mods (`Optional/Blue` vs `Optional/Red`) and on trees matching nothing — guessing there is
worse than stopping. Add-only mods fall back to directory-NAME matching and are announced as
`weak`. Verified by 9 resolver cases + an end-to-end run, then on-device first try.

⚠ Two bugs that fix found, both worth remembering:
- **`find <dir> -maxdepth 1 -iname X` matches `<dir>` ITSELF** (depth 0). Asking "is there a
  `dvdroot_ps4/` inside `game/dvdroot_ps4/`?" answered YES by self-match. Inherited from the
  old `_entries_match`, latent only because the game root's basename is a title id. Use
  `-mindepth 1`.
- **Equivalent placements are not ambiguous ones.** A mod rooted at `dvdroot_ps4/` matches at
  two depths that resolve to the SAME destination; tie-detection must key on where bytes
  LAND, not on which (root, anchor) pair produced it.
- **Cost discipline:** scoring both signals for every pair took 7.0s on the real 144-file
  mod. Two passes (names only when file-matching is inconclusive) → **0.109s**.

### UI changes pending an AppImage rebuild ON THE DECK

`ui/backend.py` has three reworded messages (both tile stages + uninstall), a
**dynamic community-mods row** that reports what is actually in `payloads/mods/`, stripping
Nexus `-<modid>-<ver>-<timestamp>` suffixes for display, the **`@@DBUI ERROR`
surfacing** and the **shuffled quote bag** landed 2026-07-22 (below), plus the
**install-location picker** landed 2026-07-24 (above). **None of it is visible yet:**
`ui/run.sh` prefers `payloads/ui/DeckBorne-$(uname -m).AppImage`, which bundles its own copy
of `backend.py`. The AppImage is arch-specific and the dev box is aarch64, so **the rebuild
must happen on the Deck**: `./ui/build-appimage.sh`. Pipeline changes need no rebuild.

⚠ When editing that stage list: rows are index-aligned with install.sh's
`@@DBUI STAGE <idx>` markers. Changing row TEXT is free; adding or removing a row shifts
every later stage. That is why the no-mods case still returns a row.

### Changes landed 2026-07-22 (all verified off-Deck; the stay-awake needs on-device proof)

1. **Fatal errors now reach the UI.** The UI deliberately surfaces no raw log lines, so
   *every* failure read as "Failed" + "Something went wrong — see the run log on the USB",
   with the actual reason (no internet, no `.pkg`, checksum mismatch…) only in a log file
   the user cannot open mid-install. `die()` in `lib.sh` now also calls `ui_error`, which
   emits `@@DBUI ERROR <msg>` — one line, newlines escaped `\n`, the terminal-friendly
   continuation indent trimmed. `backend.py` unescapes it, keeps the **FIRST** error of a
   run (install.sh's own "stage NN failed" die fires *after* the stage's message and would
   otherwise clobber the useful one), and shows it as the completion status; new `failed`
   property paints it and the headline in `cBloodHi`. Verified end-to-end against the real
   `00_preflight.sh` with `PATCHES_URL` pointed at an unreachable host — the full
   four-line network message rendered in the panel.
2. **Stay-awake during a run** — `keep_awake_begin`/`keep_awake_end` in `lib.sh`, called
   from `install.sh`'s `main` (so it covers install, uninstall AND collect, and the `ok`
   line lands *inside* the tee'd log). Every mechanism wraps a watcher with **two
   independent release conditions** — a temp flag file disappearing (normal end, via an
   EXIT trap set inside main's pipeline subshell) or the installer pid going away
   (cancel/crash) — so no exit path can strand an inhibitor. `DECKBORNE_KEEP_AWAKE=0`
   opts out.

   ⚠ **SUSPEND AND SCREEN-BLANKING ARE TWO DIFFERENT MECHANISMS. Do not conflate them
   again.** The first cut shipped only `systemd-inhibit --what=sleep:idle` and the user
   reported the screen *still* switching off mid-install on 2026-07-22. logind's idle
   inhibitor stops auto-suspend; it does **not** stop PowerDevil dimming and powering the
   panel down. That needs a ScreenSaver / PowerManagement inhibition — and those are
   released the moment the calling D-Bus connection drops, which is why `dbus-send`,
   `gdbus call` and `busctl call` are all useless here: they disconnect immediately. Every
   method has to HOLD a process open for the whole run.

   Two layers now, each independently reported:
   - **suspend** — `systemd-inhibit --what=sleep:idle:handle-lid-switch --mode=block`,
     verified against `systemd-inhibit --list` before claiming success.
   - **screen** — `_keep_awake_screen_dbus` first: a held `python3`+`dbus` process taking
     `org.freedesktop.ScreenSaver.Inhibit` **and** `org.freedesktop.PowerManagement.Inhibit`,
     which reports back through a `<flag>.screen` file naming exactly which were granted —
     so the log records what the session actually gave us, not what we asked for. Falls
     back to `kde-inhibit --power-management --screenSaver` (marked `unverified` in the log:
     it offers no grant confirmation, only that the process stayed alive).

   Read the `Staying awake for this run:` line to see which fired. Dev box gives
   `systemd-inhibit(suspend) dbus-screensaver(screen)`; the Deck should additionally grant
   `powermanagement`. If a layer is missing the run warns, and a total failure prints the
   Power Management settings workaround.
3. **Quote rotation was random-with-replacement**, so some quotes showed several times
   before others showed once — exactly what the user noticed. `Main.qml` now draws from a
   Fisher-Yates **shuffled bag** (`shuffledQuoteBag`/`nextQuote`), refilled only when
   empty, with a swap that stops a refill from repeating the quote currently on screen.
   Measured over 6 cycles of the 17 quotes: every quote exactly 6×, 0 adjacent repeats,
   17/17 unique per cycle.
4. **Artist attribution is now real, not just a mockup.** `docs/installer-attributed.jpg`
   and `docs/installing-attributed.jpg` showed an "Artwork by Snatti89" watermark bottom-left
   — but those were **edited images**; nothing in the QML ever drew it. It is now a `Text`
   on `root` (deliberately NOT inside `content`, so it renders on the home view, the
   progress view and the failure state alike), linking to the artist's Instagram via
   `Qt.openUrlExternally`. Name and URL are `win.artCreditName` / `win.artCreditUrl` at the
   top of `Main.qml` — change them there, not at the call site.
   ⚠ The user asked for "Art by Snatti89"; the mockups say **"Artwork by"** and that is what
   shipped. ⚠ Note the repo credits Snatti89 **nowhere else** — `grep -ri snatti` over the
   tree returns only this. The README's "On the art" paragraph names no creator, so the UI
   is currently the only place the attribution exists.

5. **Switching profiles no longer re-extracts 30GB.** Stage 20 used to `rm -rf` the game
   root and re-extract unconditionally, so a user who installed vanilla and then wanted
   deckborne paid ~20 minutes to change a patch set. It now skips when a **complete**
   extraction exists — `eboot.bin` for the base *and* for the update whenever an update
   `.pkg` is present, so a half-extracted install still re-extracts rather than shipping
   broken. `DECKBORNE_FORCE_EXTRACT=1` forces the old behaviour. Stage 10 was already
   idempotent, so a profile switch is now emulator-skip → game-skip → config/patches/mods
   → tile.
6. **A profile switch is a FULL switch — vanilla now reverts mods.** Settled 2026-07-22:
   vanilla means stock game FILES, not just stock settings. `40_apply_mods.sh` is now in
   **every** profile's stage list and decides by `DECKBORNE_PROFILE`:
   - **vanilla** → revert if a `.pre-mods` backup exists, else report already-stock. Exits
     before the apply path.
   - **deckborne/chocolate** → **revert first, then apply**, so what lands is exactly the
     current `payloads/mods/`. Without the revert-first, a mod DELETED from `payloads/mods/`
     would linger in the game forever.
   - anything else → `die`. A `*)` fallthrough here would silently ship a modded "vanilla".

   The revert body is now `revert_mods()`, shared by `--revert`, the vanilla path and the
   apply path. `backup_files/` stays first-write-wins, so it holds the ORIGINAL extraction's
   bytes for the life of the install and never a later modded copy — that invariant is what
   makes repeated switching safe.

   ⚠ `STAGES_VANILLA` gained a **"Restore stock game files"** row, so both profiles are now
   6 visible stages and the Steam-tile row moved 5 → 6. install.sh and backend.py were
   changed together; verified aligned for both profiles.

   Verified off-Deck over a full cycle with checksums: stock → modded → stock → modded →
   stock, back to the exact stock checksum each time, a file no mod touches preserved
   throughout, vanilla idempotent on repeat, and an unknown profile dying.
7. **Stage 50 skips when the tile is already installed.** The tile is profile-INDEPENDENT
   (Exe is the shadPS4 AppImage; LaunchOptions point at the same boot target regardless of
   profile), so a profile switch had nothing to change there — while still costing two Steam
   restarts and a warm-up launch, *the one step that has ever locked the user out of their
   desktop*. New `add_shortcut.py --exists` returns 0 only when the shortcut **and** its grid
   artwork are both present, so a tile whose artwork was lost still gets repaired rather than
   skipped. `DECKBORNE_FORCE_TILE=1` forces a rebuild. Verified against a synthetic
   `shortcuts.vdf`: shortcut+artwork → skip; shortcut but no artwork → rebuild; no shortcut →
   build; same Exe with a different `STEAM_TILE_NAME` → rebuild (different appid).

### Still stale, deliberately not fixed

- ~~UI row 4 for DeckBorne reads "Apply config & patches (60 FPS)"~~ **FIXED 2026-07-25** —
  the row is now generated from `DECKBORNE_TARGETS` and names the chosen experience
  ("… (30 FPS · 800p)" / "(60 FPS · 800p)" / "(60 FPS · 1080p)"), so it cannot drift from the
  patch set again.
- ~~README's Vanilla section~~ **FIXED 2026-07-19** — the patch table, the "nothing changes
  how the game plays" claim and deckborne's "everything vanilla, plus a frame-pacing patch"
  line were all rewritten to match the trimmed 8-patch vanilla.

### Profile history (restore strings live in `deckborne.env`)

1. **vanilla trimmed to 7 patches (`Disable Chromatic Aberration` out) and `extra_dmem`
   4000 → 2000, vanilla only** (current, 2026-07-20). ✅ **PROVEN ON-DEVICE 2026-07-20** — all
   7 patches applied (96 writes) and `extraDmemInMbytes is 2000 MB!`, both confirmed from
   `logs/state-20260720-183329/shad_log.txt`. Game installed, ran, played. Feel not yet
   reported.
2. **vanilla ← chocolate's 10-patch set, trimmed to 8; deckborne ← the same + `30 FPS++`.**
3. **Dropped `30 FPS++`** — the diagnostic that proved causation.
4. **Pivoted 60 → 30 FPS.** At 60 the Deck sat ~45 FPS with heavy judder. Ran on-device with
   all 11 patches confirmed applied by `memory_patcher`, write counts matching the XML
   exactly — so `deckborne.env` → stage 35 → XML → emulator memory is a **PROVEN** chain.
5. **60 FPS original.** Exact patch string preserved in the RECOVERY comment.

⚠ **The 30 FPS *feel* question is still open.** Nobody has reported how a locked 30 actually
plays — the artifacting took over before that was collected. A clean locked 30 confirms the
Fifo-quantization theory below; a wobbly 25–35 means the frame target was never the
bottleneck.

### Levers not yet pulled (all clash-checked against the current set, fully additive)

`Disable Dynamic Light Shadows` (*"stops a ton of heavy draw calls"* — biggest expected
win) · `Disable SSAO` · `Disable DoF` · `Disable AA` · `Model LOD 2 (Lowest)` (one step
below the current LOD 1 — alternatives, **never both**).

⚠ Note the direction: the source Reddit post ran `Model LOD -2 (Highest)` because an RX
6800 has headroom. On a Deck that **inverts** — go lower, not higher.
⚠ `Performance Patch (perf increase)` stays EXCLUDED: it clashes with four members of the
set (Light Grid 2 addrs, 30 FPS++ 5, 60 FPS++ 5, Model LOD -2 1).

## Deck hardware facts (settled — do not re-litigate)

Both cost multiple Deck trips. They are properties of *this hardware and this build*, not
of our code, and no amount of config will change them.

1. **The Vulkan pipeline cache does not work on shadPS4 v0.16.0. Four consecutive
   failures.** The cleanest test: run 1 wrote a fresh `profile.bin` from this exact device
   ("Cache dumped"); run 2, twenty minutes later, read it and **rejected** it —
   `vk_pipeline_serialization.cpp:318 WarmUp: Pipeline cache isn't compatible with current
   system.` Same device, same build, nothing changed between. Compile counts prove it
   saved nothing (291 shaders/187 pipelines vs 275/174). Disabled by default; leaving it
   on is **not** neutral — `cache_storage.cpp` has no size limit and no eviction, so it
   writes hundreds of files per launch forever and never reads them.
   **Re-test only after a shadPS4 UPDATE, and only trust a log line reading `Preloaded N
   pipelines` — absence of the warning is NOT success** (run 1 had no warning purely
   because no file existed yet). Never tested: `Vulkan.pipeline_cache_archived`.
2. **`present_mode=Immediate` is unavailable — "disable vsync" is not achievable here.**
   All four chocolate runs logged `vk_swapchain.cpp:219 FindPresentMode: Requested present
   mode Immediate is not supported, falling back to Fifo.` The driver doesn't advertise
   IMMEDIATE for this surface, so chocolate ran **Fifo** from its first sync and every perf
   observation was made under Fifo. shadPS4 accepts EXACTLY `Mailbox|Fifo|Immediate`
   (`vk_swapchain.cpp:192`); Vulkan's `FIFO_RELAXED` is **not** exposed.
   **⚠ This likely explains the whole "45 FPS with slowdown" report.** Under Fifo,
   presentation is QUANTIZED to the refresh — at vblank 60 you get 60, 30, 20 or 15 and
   nothing between. ~45fps of work alternates 60/30/60/30: the counter reads ~45 while it
   FEELS like constant judder.

**Where truth lives:** `config.json` is **not** evidence of what the emulator is doing —
`shad_log.txt` is. The env's old claim that present-mode fallbacks happen "silently" was
WRONG (both are logged), and believing it is what let chocolate run four sessions on Fifo
while its config said Immediate. Always confirm effective state from the emulator's log.

## Known bug: the warm-up can lock you out of the desktop

**Status 2026-07-17: mechanism CONFIRMED, fix in, one clean run on each path.** Kept
here rather than moved to "Recently fixed" on purpose: the bug was **intermittent**
(~2-3 failures in ~8 warm-ups), so a single clean `install.sh 50` is not proof it's
dead — it's what a lucky old run also looked like. What *has* changed is that the run
now says which happened: `stop_warmup` verifies before reporting, so a regression prints
`WARM-UP LEFT PROCESSES RUNNING` with pids instead of a cheerful lie. Move this section
once a few more stage-50 runs come back clean.

The most user-hostile thing in the repo. The warm-up is best-effort *by design* — it
must **never** cost the user anything. Three times it has cost a reboot.

**Only reproduces on a bare `install.sh 50`, never on a full uninstall/reinstall.**
The user established this by doing both back to back. It is not a shipping-path bug
today — but it is *not* cosmetic either: once mods land, re-running a single stage
against an already-installed game becomes a normal user action, which is exactly the
path that breaks. Plausible reason for the split (**unverified**): a full install has
just extracted the game, so the first launch has no shader cache and spends the whole
15s dwell still coming up, and the kill lands during early init. Run stage 50 alone and
the shaders are warm, so the game is fully up — different process state, different
outcome. Fits the intermittency too.

**Observed on-device (facts — keep these straight, they rule things out):**

- Happens **only** during the install warm-up. Every subsequent *manual* launch of the
  same tile is clean. It is specific to the launch Steam performs while the installer
  is driving.
- The game boots fine, **fullscreen**, to the Bloodborne screen.
- **Face buttons die in-game. The mouse still works.** Not "input is lost" — the
  pointer is alive; it's *gamepad routing to the game* that stops. Any explanation
  must account for both halves.
- **The game does not exit after the 15s dwell.** Still running, *not* hung. So
  `pkill` did not do its job.
- **The lockout is the fullscreen window, not the input.** A live game owns the whole
  screen, a mouse alone can't dismiss it, and there's no keyboard on the Deck to
  alt-F4. Only a reboot recovers.
- **Intermittent.** Seen twice. Other runs — including the `BBPROBE1` probe run —
  complete normally and land the tile in Recent with artwork.

**Workaround today:** `DECKBORNE_WARMUP=0 ./install.sh` skips the warm-up entirely.
The tile lands in Recent after the first manual launch instead. Use this before
demoing the installer to anyone.

**Mechanism — mostly confirmed on-device by the `BBPROBE1` probe run
(`logs/deckborne-run-20260717-075604.log`). Read that log before touching this.**

`pkill -f "$SHADPS4_APPIMAGE_NAME"` matches on the AppImage *path*, and that path is in
the argv of **every process in Steam's launch chain**, not just the game:

```
steam-launch-wrapper --oom-score-adjust 900 -- \
  reaper SteamLaunch AppId=<appid> -- \
    /home/deck/Applications/shadps4/Shadps4-sdl.AppImage -g …/eboot.bin -f true
```

1. **CONFIRMED — the "emulator came up" check matches `reaper`, not the game.** The
   probe captured `tree[0]: 26878 reaper`. So the comment at the `started=1` loop
   ("that's the proof Steam ran it") is **false**: it proves *reaper* exists. The game
   may never have started.
2. **CONFIRMED — the chain above is real**, logged verbatim by the `%command%` probe.
   `pkill -TERM -f` therefore TERMs `steam-launch-wrapper` and `reaper` too.
3. **CONFIRMED — `pkill -f` reached exactly two processes, and the game was not one of
   them.** The real tree, logged identically on both a stage-50 run and a full install
   (`logs/deckborne-run-20260717-085822.log`, `…-090019.log`):

   ```
   reaper (19690)               [pkill -f HITS]    Steam's supervisor
   ├── 19691  AppRun            [INVISIBLE]        <-- THE GAME
   │     cmd: /bin/sh -e /tmp/.mount_Shadpsiiafog/AppRun -g …/eboot.bin -f true
   └── 19697  Shadps4-sdl.App   [pkill -f HITS]    AppImage runtime
   ```

   The AppImage's `AppRun` — which execs into shadPS4, keeping its pid — runs out of
   `/tmp/.mount_XXXX/` and **never mentions `Shadps4-sdl.AppImage` in its argv**. So the
   old kill hit Steam's supervisor and the runtime wrapper, and left the game running.
4. **CONFIRMED by symptom — killing `reaper` is what killed the face buttons.** Steam
   reads reaper's death as the session ending and tears down Steam Input: gamepad routing
   to the game stops (**face buttons die**) while desktop mouse emulation returns
   (**mouse works**). Nothing else explains *mouse yes, buttons no*, and 3 above shows
   reaper was indeed being killed while the game survived.
5. **CONFIRMED — this is why every log lied.** Once the two matching processes died,
   `pgrep` found nothing, the wait loop broke immediately, `pkill -KILL` matched nothing,
   and `warmup_recent` printed "Warm-up complete ✓" **unconditionally**. Good runs and
   bad runs produced identical logs.

Intermittency fits: `reaper` usually takes its orphans down with it on the way out. The
bad runs are the ones where it lost that race and `19691` outlived it — alive,
fullscreen, holding the screen with no gamepad routing left to dismiss it.

### The fix

`stop_warmup()` replaces the `pkill -f` block. It never matches on a name at all —
which is the whole point, since the name is what missed the game:

- **Finds Steam's reaper by appid** (`reaper SteamLaunch AppId=<appid>`), not by the
  AppImage path — the appid is the only thing that distinguishes our launch chain.
- **Kills the game, never the reaper.** Descendants are collected *by ancestry*, deepest
  first, and TERMed. reaper then observes the game exit exactly as it would on a normal
  quit, so Steam tears its input state down in the right order, on its own terms. reaper
  is only touched as a last resort, *after* the game is confirmed gone.
- **Verifies, then reports.** The old code printed success unconditionally.
- **`_pid_alive()`, not `kill -0`.** `kill -0` succeeds on a **zombie** — a process that
  exited but hasn't been reaped — so it would report a corpse as a live game. Caught by
  simulating the tree locally; the real reaper reaps promptly, but a slow reap would have
  printed a scary warning over a clean run. Reads the state char from `/proc/<pid>/stat`
  (after the last `)`, since `comm` can contain spaces and parens).

On-device 2026-07-17: `targets: 19691 19697` — it found `19691`, the process the old
pattern could never see — and reported *game confirmed stopped* on both a stage-50 run
and a full install. reaper exited on its own both times; the last-resort branch that
TERMs it never fired.

### Second layer: the warm-up runs headless (belt to `stop_warmup`'s suspenders)

`stop_warmup` makes the warm-up *reliable*; running it under a **headless gamescope**
makes a future failure *harmless*. The warm-up is the only place DeckBorne launches the
game itself, so if some new failure mode ever leaves it alive, headless means it renders
to nothing — the user keeps the desktop and its mouse instead of a fullscreen lock-out.

How (`50_steam_shortcut.sh`, gated by `DECKBORNE_WARMUP_HEADLESS`, default on):

- The tile is written with `LaunchOptions="gamescope --backend headless -- %command% -g
  <target> -f true"` **for the warm-up only**, then restored to plain `-g <target> -f
  true` right after. The canonical `gamescope … -- %command%` pattern — proven to expand
  (Steam fact 8) — so the game lands under gamescope with **no wrapper script** to depend
  on. `grid_appid()` ignores LaunchOptions, so the appid and artwork are untouched.
- **Restore is load-bearing.** A tile left with headless options would launch the user's
  real game invisibly. The restore runs whatever the warm-up's outcome, and an `EXIT`
  trap (`restore_shortcut_normal`) rewrites plain options to the file if anything
  interrupts us first. `plain_launch_options` is captured once and never mutated — that's
  what restore always writes, even if the `%command%` probe rewrote `launch_options`.
- **Cost:** one extra Steam stop/write/start after the warm-up. Negligible at install
  time; keeps the *everyday* launch path clean (no permanent wrapper in LaunchOptions).
- **gamescope sits ABOVE reaper**, so `stop_warmup` (which works down from reaper) never
  touches it. It collapses on its own once the game dies; `sweep_headless_gamescope`
  mops up any straggler. A `--backend headless` gamescope is unambiguously ours — Game
  Mode's compositor is DRM/session, never headless.
- **Fallback:** where gamescope can't go headless (the aarch64 dev box), `gamescope_
  headless_ok` returns non-zero and the warm-up runs visible — still `stop_warmup`-safe.

**UNVERIFIED until a Deck run:** that shadPS4 actually renders/registers under headless
gamescope. It doesn't have to for *safety* (a game that won't run can't lock the screen),
but if it fails to register, Recent falls back to "appears after first manual launch" —
the pre-existing best-effort degradation. The `probe_warmup_kill_targets` subtree in the
log will show whether shadPS4 came up under gamescope. Read it on the next run.

### Reading /proc for a process that may vanish

`tr … < "/proc/$pid/cmdline" 2>/dev/null` **does not suppress the error**. The SHELL
performs the redirection, so the shell reports the failure and the `2>/dev/null` — which
belongs to `tr` — never sees it. A transient child that died between `pgrep` and the read
leaked `line 115: /proc/19799/cmdline: No such file or directory` into a run log. Use
`cat "/proc/$pid/cmdline" 2>/dev/null | tr …` so the redirect belongs to the process that
opens the file (`_proc_cmdline()`). Any walk of a live process tree will hit this — the
tree changes while you read it.

Verified locally against a simulated AppImage tree (parent carrying the `.AppImage` in
argv, inner process under `/tmp/.mount_XXXX/`): the inner process — the one the old
pattern could never see — is found and stopped. That proves the *shape* of the fix, not
its behaviour against real Steam.

### Related trap: `pkill -f` catches the fisherman

`pkill -f <string>` matches any process whose **cmdline contains that string — including
the shell that ran the pkill**. Demonstrated twice while testing this: a cleanup
`pkill -f 'Shadps4-sdl.AppImage'` killed its own shell (exit 144), because the pattern
was in its argv. The installer's own cmdline (`bash ./install.sh 50`) doesn't contain the
AppImage name, so it never fired for real — but that is luck, not design. Kill by pid.

**All three mitigations once weighed here are now IMPLEMENTED** — kept as a record:

- Kill by **ancestry from reaper**, never an `-f` name pattern (`stop_warmup`). ✓
- Warm up **headless** (gamescope), which beats windowed: the game renders to nothing,
  so a stuck warm-up can't own the screen at all. Uses the same LaunchOptions-swap
  insight (options aren't in `grid_appid()`). ✓
- **Confirm the process is gone** before reporting success (`_pid_alive`, verify loop). ✓

## What comes next (polish, roughly by value)

> **▶ ACTIVE WORK is mod-pipeline hardening — see "Current state" at the top**, which also
> carries the one item that outranks everything here: **deckborne now ships a config that
> needs a mod we cannot ship.** The items below are the standing backlog.

**A. Steam's final restart steals the foreground from the installer UI.** *(User wants
this fixed; explicitly not now — it's a known headache.)* The last Steam restart at the
end of an install brings Steam's window to the FRONT, covering the DeckBorne UI. Desired:
**the installer stays in front the whole time**; Steam should come back behind it or
minimized, never stealing focus.
- Why it's hard — **don't relitigate:** the *visible* restart was the hard-won fix for the
  whole `-silent`→tray→scope saga (see "Recently fixed"). On this KDE desktop `-silent`
  goes to a tray icon that never surfaces, which reads as "Steam never came back".
- Key lever: **visibility is the FLAGS argument to `steam_start`, independent of the scope
  launch mechanism.** Options: raise the installer back on top *after* the restart
  (KWin/`wmctrl`/`kdotool`, or QML `raise()`/`requestActivate()` on a timer once Steam
  settles); OR launch Steam minimized / without focus-stealing (KWin window rules); OR
  keep Steam visible but immediately re-focus the installer. **None of these may regress
  the confirmed "Steam survives + portal stays quiet" behaviour.**

**A2. ▶ LARGELY LANDED 2026-07-25 as the `desktop` TARGET, not a profile** — see "deckborne is
THREE experiences" above. The light-grid/resolution swap and the 1080p window/internal keys are
done and verified off-Deck. **What remains of this item** is the question the note below raises
and the implementation deliberately did NOT answer: whether a desktop experience should also
invert `Model LOD 1 (Lower)` and FSR. It currently keeps both, so it differs from `deck60` in
resolution and frame rate only. Close it once someone runs it on a real desktop.

`60 FPS++` is proven to
render correctly with the vertex mod and is only blocked by Deck horsepower — so it is the
natural core of a desktop/handheld-plus profile. Groundwork already done: it is one name in
a `PATCHES_*` string, vblank needs no change (the pairing rule gives both `++` variants 60),
and stage 30's `case` now carries per-profile `SHOW_FPS_*`. What would need deciding: whether
a desktop profile also inverts the Deck-specific choices — `Model LOD 1 (Lower)`, FSR on, the
1280x800 light-grid and resolution patches are all *handheld* compromises, and the source
Reddit post they came from ran the opposite end (`Model LOD -2`, no FSR) on an RX 6800.
⚠ The light-grid patch is **resolution-keyed** — a desktop at 1080p/1440p needs a different
variant, not the 1280x800 one.

**A3. GPU selection becomes a real UI control (planned 2026-07-25, NOT this release).** Part of
the future "Emulator settings" panel — a third inline control beside "Install to:" and "Collect
logs" that edits `deckborne.env` so users never open it by hand. GPU selection is the named
first candidate: **list what shadPS4 actually reports as available and let the user choose.**
Groundwork is already in: `scripts/detect_gpu.py --json` returns the device list in
`vkEnumeratePhysicalDevices` order (the order `gpu_id` indexes), and `VULKAN_GPU_ID_DESKTOP` is
the value such a control would write.
⚠ **Auto (`-1`) must stay the default choice in that UI**, not a fallback nobody picks — the
emulator's own ranking beats a user guess, and an out-of-range index is a FATAL assert at
startup. Present it as "Auto (recommended)" with the detected devices listed below it, and
prefer disabling an index the detector cannot see over writing it.
⚠ The `--json` "auto_index" is a PREDICTION of shadPS4's choice, not a readback. Don't build a
UI that presents it as fact — mark it as expected, and only the emulator's boot log confirms it.

**B. Move off USB-only distribution.** The endgame the user wants: a `curl | bash`
one-liner so the tool isn't USB-stick-driven — fetch the pipeline and download the UI
AppImage on-device. Now that the GitHub repo exists, the AppImage should be a **release
asset** rather than built by each user. The README already has an empty "Curl method"
section waiting for this.
> Related: the user also wants Steam to eventually come back **silently/in the
> background** so the UI isn't cluttered. Compatible with any launch path — it's the
> FLAGS we'd change, not the mechanism. `-silent` currently means invisible here because
> the tray icon doesn't surface; making the tray work is a separate SNI investigation.

0. **Bank a few more clean stage-50 runs.** `stop_warmup()` is in and confirmed working
   once on each path, and the mechanism is fully understood — but the bug it replaces was
   intermittent (~2-3 in ~8), so one clean run is what a lucky *old* run looked like too.
   The difference now is that the log tells the truth either way. A handful of clean
   `install.sh 50` runs and the Known-bug section moves to "Recently fixed". The probe
   (`DECKBORNE_PROBE=1`, on by default) can retire at the same time.
1. **Narrow the `collect` snapshot.** It copies all of `localconfig.vdf`, auth tickets
   included, onto a USB stick. Only the `Software/Valve/Steam/apps` block was ever
   needed. Delete the existing `logs/state-*` dirs when done with them.
2. **Stranded legacy records.** The user's Deck has orphaned `2360460574` entries in
   `localconfig.vdf` from a since-fixed appid formula change. No shortcut points at
   them, so `--by-exe` can't find them. A `--purge-appid <id>` flag would clear them;
   deliberately not carrying a legacy-hash sweep in the code forever.
3. **Verify v1.09 is actually applied** in-game (see README Status).
4. **Mods are PROVEN and IN ACTIVE USE.** ⚠ This item used to say "PROVEN, then PARKED"
   and that `payloads/mods/` is empty — **both obsolete as of 2026-07-19.** The user
   supplies mods by hand and stage 40 applies them; the vertex-explosion fix is now a
   load-bearing part of the deckborne profile. See "Current state" for the resolver and
   the mod-dependency hazard. Two things still worth carrying:
   - **The -UPDATE shadow is now auto-mirrored (2026-07-22).** shadPS4 applies the sibling
     `-UPDATE` folder over the base at load, so a mod file whose path also exists in `-UPDATE`
     is served from the update and has NO in-game effect even though it merged correctly.
     Confirmed live: MOAL edits `dvdroot_ps4/script/talk/m27_00_00_00.talkesdbnd.dcx` and
     `m35_…`, both revised by the official v1.09 update `.pkg` (the ONLY thing that writes
     `-UPDATE` — DeckBorne and every mod merge into the base root only). Stage 40 now, by
     default (`DECKBORNE_MOD_SHADOW=mirror`), copies each shadowed file into `-UPDATE` too so
     the mod wins, backing up the update's original to `.pre-mods/update-files/` first.
     `revert_mods()` restores those, so `--revert` and the vanilla switch fully undo it.
     `DECKBORNE_MOD_SHADOW=warn` reverts to the old warn-only behaviour. ⚠ Invariants that
     make repeated switching safe, both TESTED: the update backup is first-write-wins (a
     re-apply must not overwrite the pristine `UPDATE-ORIGINAL` with a modded copy — safe only
     because deckborne reverts-first, restoring `-UPDATE` before re-reading it); and the
     mirror is restore-only on revert (the update never GAINS a path — a shadowed path exists
     in it by definition — so there is nothing to delete). Verified end-to-end: apply mirrors
     both folders, revert returns base AND update to originals, warn-mode leaves `-UPDATE`
     untouched.
   - **The locale trap.** First verified 2026-07-18 with a GameBanana font mod
     (wingdings): it applied perfectly and changed nothing. Bloodborne keeps per-language
     menu assets and reads exactly ONE, by release region. This dump is EU GOTY
     (`menu/enggb`); most mods ship US (`menu/engus`). Mirror to `enggb`. Stage 40 warns
     and points at the emulator log line that proves it. ⚠ Only fires for
     `dvdroot_ps4/menu/*/*` — a `parts/` mod like the vertex fix never trips it.
   - **Redistribution is still off the table.** Nexus ToS plus the repacked-game-asset
     problem; `config/mods.catalog` documents why. The catalog stays a POINTER LIST. That
     constraint is exactly what makes the deckborne mod dependency a hazard rather than a
     packaging detail.
   - **Stray top-level files get merged too.** `SFXR 60fps Cutscene Fix` ships
     `use-this-to-undo-60fps-skip-patch.zip` beside its `dvdroot_ps4/`, and stage 40 copies
     it into the game root. Inert, and `--revert` removes it (it lands in `added.list`), but
     it is junk in the game folder. Left alone deliberately — "ignore top-level files" could
     drop legitimate ones.
5. **`git init` + first commit**, once the above settles.

### Recently fixed (don't re-break)

- **Uninstall left Steam down** (`99_uninstall.sh`). Two rounds:
  - *Round 1:* it restarted Steam mid-run — right after the tile edit, *before* the
    emulator and game were removed — with a terse fire-and-forget `[ … ] && steam_start`.
    Moved the restart to the **end** (Steam stays stopped for the whole uninstall: the
    localconfig/shortcuts edit needs it off, file removal doesn't need it on) and
    initialised `STEAM_WAS_RUNNING` at the top so the end guard is `set -u`-safe on the
    dry-run path (which never calls steam_stop).
  - *Round 2:* Round 1's verify was a bare `pgrep -x steam`, which logged "Steam is back
    up" while Steam was down — same class of bug as the warm-up, **existence proves a
    process flickered, not that the app stayed up.** Now: wait for `steam`, settle
    `DECKBORNE_STEAM_SETTLE`s, confirm `steam` *and* `steamwebhelper` are up. That footgun
    (reaper vs game, zombie vs alive, launcher vs client) is this project's recurring one —
    never verify a process by a single name match.

  **ROOT CAUSE FOUND & FIXED — it was `-silent`.** Confirmed on-device 2026-07-17: the
  uninstall run with `STEAM_START_FLAGS=` (empty, no `-silent`) opened Steam's window,
  and its diagnostics showed `cgroup=app-steam-72031.scope` and
  `display=[WAYLAND_DISPLAY=wayland-0 DISPLAY=:0]` — i.e. **scope and display were never
  the problem; both are identical with or without `-silent`.** On this Deck's KDE desktop
  `steam -silent` starts to a tray icon that never surfaces, so it read as "Steam never
  came back". The install showed the *same* thing: the warm-up's restore step does a
  by-design `steam_stop` (needed to rewrite the tile's launch options) then a `-silent`
  restart — which looked like "kill game → shut Steam down → nothing returns", when Steam
  had in fact restarted invisibly. The headless warm-up masked it for weeks because a
  headless gamescope game needs no Steam UI.

  **The fix has THREE parts, found in this order (each round taught the next):**
  - *Visibility (`-silent`):* `steam_start` takes an optional flags arg (default
    `$STEAM_START_FLAGS` = `-silent`, for the warm-up's transient internal restart). The
    user-facing restarts pass `""` → a visible window, because `-silent` goes to a KDE tray
    icon that never surfaces here.
  - *Confirmation, not a race:* `steam_restart_visible()` in `lib.sh` waits for `steam` to
    appear, settles (`DECKBORNE_STEAM_SETTLE`), then confirms `steam`+`steamwebhelper`.
    (An early theory was that exiting too fast raced the launch. WRONG — see next.) BOTH
    user-facing restarts (install restore in `50_steam_shortcut.sh`, uninstall in
    `99_uninstall.sh`) call it, so they can't drift apart. Never bare-`steam_start` a
    restart the user should see.
  - *Detachment — the real fix (2026-07-17):* even after visibility + wait, Steam came up
    **visible and confirmed** (steam_restart_visible logged "Steam is back up", steamwebhelper
    present) and then **force-closed the instant the script exited** — on BOTH install and
    uninstall. So the kill wasn't a failed launch or a race; it was the `--scope` being torn
    down with the caller's process tree (a scope runs inside the caller's tree, and `disown`
    only blocks SIGHUP, not this). `steam_start` now launches a `--user` **service**
    (`systemd-run --user --collect --unit=app-steam-<pid>`, `--setenv` forwarding the
    graphical vars), which the systemd user manager owns and which survives the script.

  **CONFIRMED FIXED on-device 2026-07-17 (logs 131756 / 132437):** the `--user` service
  survives the script exit — Steam comes back and STAYS on both install and uninstall.
  Core bug closed.

  **Portal-prompt regression — FIXED & confirmed on-device 2026-07-17.** The interim
  scope→service switch reclaimed Steam's *lifetime* but lost its *portal identity*
  (Steam fact 7). `xdg-desktop-portal` recognizes `.scope` app-units and extracts the
  stable app-id `steam` from `app-steam-<pid>.scope` (ignoring the pid suffix). It does NOT
  parse `.service` units the same way — it falls back to the raw PID
  (`app-steam-<pid>.service` → shows the `$$`), and since that PID changes every run the
  restore token never matches → "choose which screen to share with <pid>" on EVERY
  install/uninstall.
  **The fix (now the unconditional default in `steam_start`):** launch Steam as
  `setsid systemd-run --user --scope --unit=app-steam-<pid> -- steam`. A `.scope` is
  portal-recognized so the prompt stays quiet; `setsid` gives it a new session so the
  script's exit can't reap it (the detachment the `--user` service got from the manager,
  without the service's portal blind spot). Confirmed on the Deck: Steam STAYS up AND the
  screen-share prompt is gone. The `STEAM_SCOPE_LAUNCH` flag and the obsolete `--user`
  service branch are both **removed** — `steam_can_scope` gates it, plain `setsid steam` is
  the no-user-bus fallback.

  **Edge left open (low priority):** if `DECKBORNE_WARMUP_HEADLESS=0` (headless disabled),
  stage 50 has no restore step, so the final Steam state is the warm-up's `-silent` #1 →
  invisible. Not the Deck's default path (gamescope headless always works there), so
  deferred. Fix if it ever bites: surface Steam at the end of stage 50 in the non-headless
  branch too.

  **Cosmetic note (works, don't rush to fix):** with headless gamescope, `_reaper_pid`
  matches the **gamescope** process, not the real reaper — gamescope's argv contains the
  whole `reaper SteamLaunch AppId=…` string. `stop_warmup` then anchors on gamescope and
  kills its entire subtree (which still stops the game correctly — see the 114756 log,
  "game confirmed stopped"). The log line `reaper=<pid>` is therefore mislabelled but the
  behaviour is right. Tidy only if reworking the warm-up.

- **Logs dying on the USB — the second time.** The 0-byte-log bug below was about the
  shell not waiting on a process substitution. This one is different and the symptom is
  identical, so don't confuse them: `finalize_log()` wrote the log correctly and never
  called `sync`. The log lives on removable exFAT, and the runs worth reading are exactly
  the ones ending in a yanked stick or a held power button. On 2026-07-17 two probe runs
  finalised cleanly — `latest.log` was written 0.01s after the run log, so `[ -s ]` had
  passed and the content was *there* — and both arrived at the dev box as 0 bytes. The
  directory entries had flushed; the data had not. An entire Deck trip's evidence was
  lost. `finalize_log()` now ends in `sync`. **Tell-tale:** a 0-byte log *next to* a
  populated `extract-*.log` from the same run means data loss, not a logging failure.

- **Interrupted installs stranding 30GB.** `20_install_game.sh` traps `EXIT INT TERM`
  to sweep `.extract-tmp`. Safe on success because the game root is `mv`d out of tmp
  before the trap fires — verify that stays true if the extract flow is reworked.

- **0-byte logs.** `install.sh` used `tee >(sed … >> "$LOG_FILE")`; the shell does not
  wait on a process substitution, so a run could exit or be interrupted before sed
  flushed — leaving an empty log and losing the output of exactly the runs worth
  reading. Now: `tee "$LOG_FILE.raw"` in the pipeline proper, colors stripped after,
  finalised by an `EXIT INT TERM` trap. `latest.log` is a copy, not a symlink (exFAT).
- **The dry-run that wasn't.** `step "…${DRY:+ (dry run)}"` expands for any *non-empty*
  value, and `DRY=0` is non-empty — so every real uninstall printed "nothing will be
  deleted" while deleting everything. Use explicit `[ "$DRY" = 1 ]` tests.
- **Uninstall matching by Exe.** `shortcuts.vdf` is rewritten by Steam on exit, so its
  key casing and Exe quoting are Steam's by the time an uninstall reads it. Read
  fields case-insensitively (`_field()`), normalise paths, and fall back to
  name-matching. An exact `v.get("Exe")` comparison silently matched nothing.

## Conventions

- `config/deckborne.env` is the single source of truth for versions, checksums, paths,
  IDs. Values there, not inline. Env-overridable where it helps testing.
- Shell scripts source `lib.sh` then `load_env`; use `step`/`ok`/`warn`/`die` for
  output so it lands in the run log consistently.
- Cleanup and best-effort niceties (warm-up, play-record purge) must **never** fail an
  install or uninstall — catch, warn, continue.
- Anything destructive gets a backup (`*.deckborne.bak`) and an atomic write.
