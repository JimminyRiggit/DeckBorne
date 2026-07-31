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
  then copy to the stick's `DeckBorne/` directory. ⚠ The volume label is **PortaBrain**
  (`/run/media/<user>/PortaBrain/DeckBorne/`) — older notes here said `RuhRoh`, which is wrong.
  Never author on the stick.
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

**▶ Latest first (2026-07-28).** Three things changed today, in order of how badly a future
session needs them:

1. **Saves.** Two findings, both in "Export / Import Save" below: the **save title-id is not the
   disc title-id** (`CUSA00207/SPRJ0005`, not `CUSA03173`), and the **two-way "newer wins" sync
   was removed** in favour of two explicit one-way actions — restoring it would re-break
   importing a save from another machine.
2. **What the Deck reported back** on the first real Workshop session — the settings matrix,
   the leak rule proven on hardware, and two settled-negative findings reconfirmed.
3. **UI polish batch** — panel open/close rules, scrollbar, pill width, copy.

Everything on the stick is current. The AppImage on it is **not** — it dates from 2026-07-27
21:38, so every `ui/` change since then (including the two save buttons) needs
`./ui/build-appimage.sh` **on the Deck** to be visible. `scripts/` and `config/` changes need
no rebuild.

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

✅ **RAN ON HARDWARE 2026-07-28** — once, on the Deck, and every predicted write count matched
the XML exactly: `Optimal 1080p` **76**, `1080p Light Grid` **2**, `Model LOD -2 (Highest)` **1**
(with `Model LOD 1` absent from that launch, so the swap is confirmed, not merely intended).
Evidence: `logs/state-20260728-163803/shad_log.txt` on the stick. ⚠ The earlier "NEVER RUN ON
ANY HARDWARE" warning is RESOLVED — do not reinstate it. ⚠ Still unreported: how it *looks* and
whether a desktop holds 60 at 1080p; it ran on a Deck, which is not the hardware it is for.

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
- **QML, 21 checks** against a real offscreen render (`.venv-ui` + `main.py --shot`): three
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

### ▶ NEW 2026-07-27: "The Workshop" — user-chosen emulator settings

**Verified off-Deck only (53 pipeline checks + 30 QML checks, all green). Nothing here has
run on a Deck.** This is A3 from the backlog, landed as its own inline control: a
**"The Workshop"** button sitting between *Install to:* and *Collect logs*, opening a panel
of shadPS4 settings. Three settings ship: **graphics device**, **on-screen FPS counter**,
**allow HDR output**.

**⚠ The store is `$HOME/.local/share/DeckBorne/settings.env`, NOT `config/deckborne.env`.**
A3 said "edits deckborne.env"; that was rejected on four counts, all of which still hold —
deckborne.env is git-tracked (user settings would show as a dirty working tree), it lives on
the exFAT USB (the medium that already corrupted two source files), it is what the planned
`curl | bash` distribution would re-fetch and clobber, and the stick can be absent or
read-only when the UI runs. Same reasoning that put `storage_root` in `$HOME`. **Do not
"consolidate" these back into deckborne.env** — the benched goal of making deckborne.env
user-facing is about the SHIPPED defaults being readable, not about storing user state there.

**Precedence is `env > Workshop > shipped default`, and it falls out of the file format
rather than being enforced anywhere.** `load_env` sources `settings.env` FIRST, and that file
uses the same `${VAR:-value}` idiom deckborne.env does — so deckborne.env's own
`${VAR:-default}` sees the variable already set and keeps it, while an explicit environment
variable beats both. `SHOW_FPS_DECKBORNE=true ./install.sh 30` still works untouched.
⚠ `load_env` therefore spells out the `DECKBORNE_STATE_DIR` default a SECOND time — it has to,
because deckborne.env is what defines that variable and it has not been read yet at that point.
Change one, change the other.

**Only NON-DEFAULT values are written**, and setting everything back to Auto deletes the file.
That is deliberate: a user who never opens the Workshop has no file, and a shipped default
changed later still reaches everyone who never overrode it.

**Three new variables, and each is resolved so the leak rule still holds** (config.json is
MERGED — a key one profile writes and another omits does not revert, it persists):

- **`VULKAN_GPU_ID`** (default `-1`) is the new global. Stage 30 initialises `gpu_id` from it
  instead of the old hardcoded `-1`, so EVERY profile and target writes the user's choice.
  `VULKAN_GPU_ID_DESKTOP` now defaults to `$VULKAN_GPU_ID`, so the desktop escape hatch still
  overrides but no longer silently ignores a Workshop choice.
- **`DECKBORNE_FPS_COUNTER`**, **`DECKBORNE_HDR`** and **`DECKBORNE_SHADER_CACHE`** are
  `auto|on|off`; **`DECKBORNE_PRESENT_MODE`** is `auto|fifo|mailbox|immediate`. `auto` leaves
  the per-profile value alone (`SHOW_FPS_*` / `HDR_*` / `PIPELINE_CACHE*` / `PRESENT_MODE_*`);
  anything else forces. All resolved AFTER the profile `case`, so they are genuine overrides
  rather than competing sources of truth.
  ⚠ An unrecognised value **dies** — no `*)` fallthrough, same rule as everywhere else here.

**⚠ Present mode and shader cache are exposed DESPITE both being settled-negative on this
hardware** (user's call 2026-07-27: "while we have these set hard defined, if a user wants to
adjust they should"). Both default to `auto`, so an untouched install is byte-identical to
before. **Do not read their presence in the UI as the Deck-hardware findings being reopened** —
see "Deck hardware facts": `Immediate` is not advertised by the driver and falls back to Fifo,
and the pipeline cache failed five consecutive on-device tests while writing hundreds of
unread files per launch. Stage 30 therefore **warns loudly** whenever either is forced, naming
the exact log line that would prove otherwise (`Preloaded N pipelines` / the present-mode
fallback). The blurbs say the same thing in one line each.
⚠ Fixed while adding this: the closing "Vulkan pipeline cache ON" note tested the GLOBAL
`$PIPELINE_CACHE`, not the resolved `$pcache`, so it would never have fired for a
Workshop-enabled cache (nor for a profile that set `PIPELINE_CACHE_CHOCOLATE`).

**The pill rows are SCHEMA-DRIVEN** (`kind: "pills"` + an `options` list in
`user_settings.py`), not hardcoded auto/on/off — that is what let present mode have three
choices without touching the QML. Adding a setting is now a `SETTINGS` entry plus a `case` in
stage 30; the UI needs no change.

**⚠⚠ THERE IS NO "AUTO" PILL, BUT `auto` IS STILL THE STORED DEFAULT** (user's call
2026-07-27: "remove auto as an option and just have the option set as the highlighted
option"). This distinction is the whole design and is easy to destroy by accident:

- The panel shows only real values (On/Off, Fifo/Mailbox/Immediate, the actual GPUs). The one
  that `auto` currently RESOLVES TO is the highlighted one, so the user reads their effective
  setting instead of the word "Auto".
- **Clicking the already-highlighted option stores `auto`, not the literal value**
  (`WorkshopModel.set_value`). That is what keeps an untouched — or re-selected — setting
  FOLLOWING THE PROFILE. Store the literal instead and a user who taps "Off" on the FPS
  counter has silently pinned it, so a later Vanilla↔DeckBorne switch no longer moves it.
  Same for the GPU: clicking the auto-picked device stores `-1`, never its index (which also
  keeps the fatal out-of-range assert out of reach).
- The gold "modified" dot and the *Restore DeckBorne defaults* button therefore mean "diverges
  from the shipped behaviour", not "has been clicked".

**What `auto` resolves to is READ FROM `deckborne.env`, not duplicated in the UI** —
`user_settings.auto_values()` sources `lib.sh` + `load_env` and reads `SHOW_FPS_DECKBORNE`,
`HDR_DECKBORNE`, `PRESENT_MODE_DECKBORNE`, `PIPELINE_CACHE`, mapping `true/false` → `on/off`.
So the highlight cannot drift from what stage 30 will actually write. `auto_fallback` in each
spec covers the env being unreadable.

⚠ **It resolves against the DECKBORNE profile, and HDR is the one place that lies.** Vanilla
sets `HDR_VANILLA=false` while deckborne sets `true`, so the panel highlights "On" even though
a Vanilla install with the setting left on `auto` will write `false`. Every other setting is
identical across vanilla/deckborne today (FPS off, Fifo, cache off), so HDR is the only
mismatch. Options if it ever matters: show the resolution per selected profile (the panel is
profile-agnostic today), or flatten `HDR_*` to one shipped value — ⚠ the latter would undo the
deliberate 2026-07-25 call that vanilla means the stock game.

⚠ QML now reads `modelData.selected` computed BY THE BACKEND rather than comparing
`modelData.value === ws.value`. Value-comparison cannot express "this is what auto resolves
to" for the GPU rows, whose unverified entries all carry an empty value.

**Detection is THREE tiers, so the panel always names a device (2026-07-27).** `vulkaninfo` →
`lspci` → `/sys/class/drm`. Only the first reports `vkEnumeratePhysicalDevices` order; the
other two exist so a machine without vulkan-tools sees its APU listed by name instead of an
empty "no GPUs could be enumerated" state. The sysfs tier reads the PCI `vendor`/`device`
files, falling back to the DRM `DRIVER=` from `uevent` for non-PCI (ARM) display controllers,
and `lspci` names are tidied ("Advanced Micro Devices, Inc. [AMD/ATI] VanGogh […]" →
"AMD VanGogh […]") so they fit one line.

**The device choices are INLINE BOXES** (`GpuBox`, styled off `FpsPill`), not a stacked list —
there is realistically never more than one or two devices. ⚠ **There is NO "Auto" box any more
(2026-07-27)** — the row lists only real devices, and the one `auto` resolves to is the
highlighted one, exactly the rule the pills follow. Clicking the highlighted device stores
`-1`, never its index. An earlier cut had a fixed 116px "Auto / RECOMMENDED" box; it is gone,
and `qml_probe.py` now asserts its absence. Devices carry a short uppercase spec
("INTEGRATED · VULKAN 1.3"). Long names are shortened for the box by stripping a trailing
bracketed group (`_short_name`: "AMD VanGogh [AMD Custom GPU 0405]" → "AMD Custom GPU 0405"),
and the full sentence moved OUT of the boxes into a **`caption` role** under the row
("Auto renders on <device>."). ⚠ Keep box text short — the boxes are fixed-height (62px, name
capped at 2 lines) so a long label elides rather than growing the row.

⚠ **Fallback devices are LISTED BUT NOT SELECTABLE**, dimmed, carrying an empty value, with the
reason folded into the caption ("… Install vulkan-tools to choose one explicitly.") — the same
treatment the storage picker gives an exFAT card, for the same reason: hiding it leaves the
user hunting. Auto stays selected and its detail line NAMES the device
("Uses AMD VanGogh […] — the only graphics device found"), which is what makes the APU visibly
auto-detected without a guessed index ever being written. **Do not "finish" this by making
those rows selectable** — an index from lspci/sysfs order is not a Vulkan index, and on a
multi-GPU box picking the first listed device would silently select the *weaker* one, which is
strictly worse than Auto.

**⚠⚠ An out-of-range `Vulkan.gpu_id` is a FATAL assert at startup, so stage 30 now REFUSES one.**
`detect_gpu.py --validate <idx>` exits 0 (in range), 1 (out of range), 2 (cannot verify —
no vulkaninfo). On 1 the stage **falls back to `-1` and says so loudly**; on 2 it honours the
value but warns hard. The UI only ever offers indices `vulkaninfo` actually reported — an
`lspci` list is NOT `vkEnumeratePhysicalDevices` order, so offering it would be offering a
wrong index. This closes the risk A3 flagged ("prefer disabling an index the detector cannot
see over writing it") rather than just documenting it.
⚠ **Auto is still the right answer and the UI says so** ("Auto (recommended)", with the device
shadPS4 is *expected* to pick shown as a prediction, never as a readback). Do not turn the
prediction into a claim — only the emulator's boot log confirms what it chose.

**`scripts/user_settings.py` is the single source of truth for the schema**, and it lives in
`scripts/` NOT `ui/` for exactly the reason `detect_storage.py` does: the AppImage bundles
`ui/` only and resolves the pipeline at runtime, so settings can be fixed by editing the USB
with no AppImage rebuild — and that rebuild has to happen on the Deck. `backend.py` shells out
to it (`--json` / `--set`), and **degrades to a "settings unavailable" panel** rather than
blocking anything when the script is missing (new AppImage, old USB). Verified.

**UI shape:** the Workshop button carries a small gold dot when anything differs from the
defaults. The panel footer has a **"Restore DeckBorne defaults"** `FootButton` (bottom right) —
a compact 22px bordered action (`Main.qml`), NOT a GhostButton; both panel footers use it,
which is `installer.resetWorkshop()` → `user_settings.py --reset` → the file is deleted and
the shipped `deckborne.env` values apply again. It is **disabled and relabelled "Using
DeckBorne defaults"** when nothing is changed, so the button doubles as the state readout —
that replaced an earlier "All defaults / Changed from the defaults" text pair, which was
redundant next to it.

**Panel geometry (settled 2026-07-27, user's call):** the popup **drops DOWN from the button
and fills every pixel between it and the window's bottom edge** — `y = shop.height + 6`,
`height = root.height - <mapped bottom of the button> - 6 - 12`.
⚠ **`dropHeight` is a BINDING with a deliberate dummy dependency** (`reflowDeps`, summing
`root.height` and the button row's `y`). `mapToItem()` does not re-evaluate on its own, so
without touching those two reactive values the binding never re-runs — the panel keeps the size
it had when first opened, and a resized window leaves it stranded at the old height. That was
observed: rendering at 1000px tall still produced a 212px panel. Computing it in
`onAboutToShow` instead also works but silently breaks on a resize while open, which is why it
is a binding. **Do not "clean up" the unused variable.** It always scrolls (content is
~450px against ~210px of space at the default 680-tall window), so the `ScrollBar` is styled
gold-on-faint and pinned `AlwaysOn` whenever `contentHeight > height` — the scroll affordance
is load-bearing here, not decoration.
⚠ An earlier cut opened UPWARD and floated to the top of the window when the content did not
fit; that showed all three settings at once but was rejected. **Do not reintroduce it.** If the
cramped height ever needs solving, the fix is fewer/shorter settings or a taller window — not
flipping the direction back.

**Panel artwork (2026-07-27):** `ui/art/the-workshop.jpg` (the Hunter's Workshop, 1920×1242)
is the popup background, credited bottom-left as **"Artwork by Ishutani"** linking to
`https://ishime.carrd.co/#char`.
**Both bottom-row panels share it** — `PanelBackground`, `PanelScrollBar` and `PanelCredit`
are inline components used by the Workshop AND the *Install to:* picker, so the two read as
one surface (user's call 2026-07-27). Change the chrome in those components, not at either
call site; the context property is still named `workshopBgUrl` even though both use it.
**Both panels carry the Ishutani credit**, since both now show that artwork.

⚠ **THE ART CREDIT LIVES IN EACH PANEL'S FOOTER, AND THE WINDOW'S OWN CREDIT HIDES WHILE A
PANEL IS OPEN.** `PanelCredit` sits at the left of both pinned footers; the window's
"Artwork by Snatti89" goes to `opacity: 0` / `visible: false` whenever `win.openPanels > 0`
(counted in each Popup's `onOpened`/`onClosed`). That is what stopped the window credit
showing through the storage panel, which is centred on its button and overlaps it.
⚠ **An intermediate design put ONE static credit at the window bottom that swapped its text to
name whichever artwork was showing. It was rejected 2026-07-27 — "get rid of it" — and rolled
back. Do not reintroduce it.** The credit belongs to the surface it credits.

⚠ **Each panel's footer lives OUTSIDE its Flickable**, pinned by
`ColumnLayout { Flickable { Layout.fillHeight }, rule, footer }`. It used to be the last item
*inside* the scrolling column, so *Restore DeckBorne defaults* / *Rescan devices* scrolled out
of reach exactly when the content was long enough to need them. Do not fold it back in.
⚠ **The two panels deliberately size DIFFERENTLY.** The Workshop fills the space to the bottom
edge; the storage list sizes to its content and only *caps* at the same edge (`Math.min(content,
dropHeight)`). Forcing storage to fill left a large empty expanse of artwork whenever a user has
only internal storage — a realistic case. Matching chrome, not matching height, was the ask. Name and URL are `win.shopCreditName` / `win.shopCreditUrl`
at the top of `Main.qml`, mirroring the Snatti89 pair — change them there, not at the call
site. The credit renders even when the settings panel itself is unavailable, since the art
is showing either way. Now credited in README's Credits section too.
- ⚠ **It MUST be `.jpg`.** `build-appimage.sh` stages `art/*.jpg`; the source file was a
  `.jpeg` and would have been silently dropped from the AppImage — the panel would have shown
  a plain dark background on the Deck only, and looked perfect on the dev box.
- ⚠ **Scrim tuning is load-bearing, not decoration.** The artwork is busy, so the first pass
  (gradient at 0.86 alpha) hid it completely and the second (0.50) made the body text
  unreadable. It sits at 0.80/0.72/0.84 over the image at 0.9. Re-check by RENDERING if the
  image or the panel's text colours ever change.
- ⚠⚠ **THE FOOTER SCRIM IS A *VERTICAL* FADE AND THE FLICKABLE RUNS UNDER IT (2026-07-29,
  user's call). The direction of that gradient is the whole point — do not "restore" a
  horizontal one.** Separate scrim from the one above; the panel gradient was not touched.
  - **What was wrong:** each pinned footer had a `Rectangle` with a *horizontal* gradient
    (0.96 alpha left → 0.66 → 0.0 right). A left-dark band reads as **a bar**, so content
    scrolling up to the Flickable's clip line looked like it was "peeking over a border".
  - **Dead end #1 — transparent footer.** Removed the bar, but the clip line was still a hard
    horizontal cut ~50px above the panel edge, with dead space below it. Still read as a ledge.
  - **Dead end #2 — footer overlaying content, no scrim.** Content then reached the bottom, but
    the pinned credit landed *on top of* live content text. A backing chip behind the credit
    (tried translucent, then opaque) only made it worse — it partially occluded content mid-line.
  - **What works:** `contentItem` is an `Item` (not a `ColumnLayout`), the `Flickable` is
    `anchors.fill: parent` so it reaches the panel's inner bottom edge, and the footer is
    `anchors.bottom` **over** it carrying a VERTICAL gradient (alpha 0.0 → 0.72 @35% → 0.97
    @62% → 1.0), height 54. Content dissolves into the bottom instead of being cut, which
    doubles as the "there is more below" affordance.
  - ⚠ **`contentHeight` MUST include the footer** (`… + footer.height + 4`) or the last setting
    sits under the footer at full scroll and cannot be read. That 4px is the clearance.
  - ⚠⚠ **`PanelScrollBar` IS NOT ATTACHED — it is an anchored sibling, and it must stay that
    way.** With the Flickable running to the panel's bottom edge, an attached
    `ScrollBar.vertical` ran its track down *behind the footer*, so the thumb slid under the
    *Restore/Using DeckBorne defaults* button.
    **`ScrollBar.vertical` cannot be constrained by a height binding.** The attached object sets
    the scrollbar's height **imperatively from C++** (to the Flickable's height), which
    **silently destroys any declared `height:` binding.** A first fix added a `bottomGap`
    property and bound `height: view.height - bottomGap`; it read back as `bottomGap=46` and
    `height=309` — the gap was stored and the height ignored. It looked plausible and changed
    nothing.
    **The fix:** drop `ScrollBar.vertical:` entirely and declare `PanelScrollBar` as a sibling of
    the Flickable, `anchors.top: parent.top` / `anchors.bottom: <footer>.top`, driven manually —
    `size: view.visibleArea.heightRatio`, `position: view.visibleArea.yPosition`, and
    `onPositionChanged: if (pressed && view) view.contentY = position * view.contentHeight`
    for dragging. Wheel scrolling still goes to the Flickable. Confirmed: `height=263` (309 − 46)
    and the thumb bottoms out above the button.
    Footer trimmed 54→46 and its `topMargin` 18→12 at the same time, to cut the gap after the
    last row. Content slack is **4px** (content 451, viewport 309, footer 46 → 188 needed vs 192
    actual) — the clearance and nothing more, so the *content* never scrolled past the bottom;
    it was always the bar's track.
  - ⚠ **Verify scrollbar geometry with `QQmlProperty.read`, NOT by eye and NOT by pixel-scanning.**
    `o.property("height")` returns `None` on these wrappers, and hunting the thumb by colour
    picks up the gold pills and the panel border instead — two separate wrong measurements here
    "confirmed" a fix that was not working. `findChildren(object)` + `metaObject().className()`
    matching `"PanelScrollBar"` (the component name, *not* `QQuickScrollBar`) finds them.
  - Verified by rendering at Deck size (1280×800): fade correct unscrolled, **scrolled to the
    end the last row (`Shader cache`) is fully legible and clear of the footer**, storage panel
    measures `contentHeight == height` (no scroll, content ends 4px before the fade), no QML
    warnings.
  ⚠ If a dark bottom edge is ever still visible, the remaining contributor is
  `PanelBackground`'s own bottom gradient stop (**0.84**, against 0.72 at the middle) —
  deliberately darker, and a different knob from the footer.
  ⚠ **Do NOT reach for `QtQuick.Effects`/`MultiEffect` for this.** It resolves fine on the dev
  box, but a new QML import is the `.jpeg`-art failure mode with teeth: if the module is not
  in the AppImage, Main.qml does not load *at all* — the UI simply fails to start, on the Deck
  only. The vertical-gradient fade needs no new import.
  ⚠ **Rendering the panels needs a window taller than the 680 default** — at 680 the drop-down
  is clipped by the window and its footer is off-screen entirely, so a shot at the default size
  cannot show this area at all. `ui/main.py --shot` has no size flag; drive it from a throwaway
  script that imports `main` for the context-property wiring and sets `width`/`height` on the
  root window before grabbing. ⚠ Panel height is **not** deterministic between runs (the
  `dropHeight` binding settles asynchronously), so two shots are not pixel-comparable — do not
  read a layout difference between before/after shots as a change you caused.
- `build-appimage.sh`'s staged-vs-source `cmp` gate now covers `art/*` as well as the Python
  and QML, so a USB-corrupted image is refused at build time instead of shipping. Same
  reasoning as the existing gate — that is the failure mode which already zeroed `icon.ico`.

⚠ **Uninstall deliberately does NOT delete `settings.env`.** It is a preference, not install
state — a reinstall should keep your choices. That is the opposite of `storage_root`, which
IS forgotten, because that one describes where bytes went.

⚠ **The settings apply on the NEXT INSTALL only** — there is no "apply now", by choice. A
profile switch is enough to pick them up (it re-runs stage 30), so the cost is small, and an
"apply now" would have to run stage 30 standalone, which still trips the `game-pkg/`
requirement below.

⚠ **Needs an AppImage rebuild ON THE DECK to be visible**, like every `ui/` change.

**⚠ Testing note that cost real time — do not repeat it.** Repeater delegates are **not** in
`QObject::children()`, so a `findChildren`-based probe silently reports zero rows for a panel
that renders perfectly. Reaching the visual tree needs a `QQuickItem` cast, and `shiboken`
returns a **cached `QObject` wrapper** for some nodes, so the cast fails unpredictably —
several attempts at a generic walker each failed differently. What actually settled it was
`ui/main.py --shot --open 8` and **looking at the PNG**. The probe now asserts the model
wiring, the Repeater *counts*, and the persistence round-trip; delegate CONTENT is verified
visually. `--open 8` is the Workshop's screenshot hook (storage uses 9).

Probes (throwaway — rewrite rather than trust a stale copy):
`scratchpad/workshop_probe.sh` (**68** checks: precedence, tri-state resolution across all three
profiles and all three targets, the leak rule, GPU validation incl. an out-of-range refusal
against a synthetic `vulkaninfo`, a bad stored value dying, the user's own emulator settings
surviving) and `scratchpad/qml_probe.py` (**64** checks). Two more suites landed 2026-07-28:
`scratchpad/panel_probe.py` (**27**, the bottom-row panel open/close rules) and
`scratchpad/saves_probe.sh` (**44**, save discovery, direction, and the damage/backup guards).
⚠ Two probe-authoring traps, both of which cost time here: reading a QML **enum** property
(`Image.status`) from Python raises `Can't find converter`, so assert on `progress`/`sourceSize`
instead; and **an exception thrown inside the `QTimer` callback leaves the event loop running**,
so the probe HANGS rather than failing — wrap the check body and `app.exit()` from the handler.

### ▶ Export / Import Save (two-way sync REMOVED 2026-07-28 — read this before "improving" it)

**Two explicit one-way actions**, `Export save` and `Import save`, in the *Install to:* panel
footer. Between shadPS4 and `$DECKBORNE_ROOT/savefiles/<save-title-id>/` (gitignored, and
excluded from any repo→USB rsync — it is user data, like `logs/`).

- `install.sh saves-export` → `sync_saves.sh --export` — Deck → DeckBorne
- `install.sh saves-import` → `sync_saves.sh --import` — DeckBorne → Deck
- bare `install.sh saves` runs NOTHING; it dies telling you to pick a direction.
- The direction argument is **mandatory**; an absent or unknown one dies with usage.

⚠⚠ **THERE IS DELIBERATELY NO TIMESTAMP COMPARISON, AND RESTORING ONE IS A REGRESSION.**
The first cut was a two-way sync with `rsync --update` (newer file wins each way). The user
found the hole by reasoning about it, before it ever bit: **a save carried in from another
machine is normally OLDER than the one already on the Deck.** The export leg runs first, so
that copy would be overwritten on the stick by the Deck's newer save and then never imported —
the exact operation the feature exists for, failing silently, with the carried-in save
recoverable only from a `.bak` nobody would think to look in.
It is worse than merely wrong: whether the incoming file even *looks* older depends on how it
was copied (`cp` without `-p` stamps it now; `cp -a` or a file manager preserves the original),
so the same user action produced opposite outcomes. **Modification time does not express
intent.** The direction the user clicked does.

**What the copy now is:** unconditional `rsync -a` in the chosen direction (no `--update`), the
destination copied to a dated `.bak-<stamp>` first, then `sync`, then verification.

**The backup is taken only when something would actually be overwritten (2026-07-28).** An
`rsync --dry-run` runs first; if it reports no changes, no `.bak` is made and the run says so.
Every run used to leave a full snapshot — on a 15 MB save, two no-op runs cost 30 MB of exact
duplicates. ⚠ Verification still runs on a no-op path: a run that copies nothing must still
*prove* the two sides match rather than assume it.
⚠ **`backup_side` returns 0 ONLY if a backup really exists afterwards.** It used to return 0
when it had skipped (destination absent) or when the `cp` failed, so the closing line promised
a `.bak-<stamp>` that was not there — this project's signature failure, in the one feature where
a false promise costs a save. The final message is driven by that return value, not by intent.

⚠ **A forced direction makes a damaged SOURCE dangerous**, which two-way self-healing used to
absorb — so the run now **refuses before touching anything** if the source holds any 0-byte
`userdata####`/`backup####` slot. Nothing is copied and no backup is even taken. PS4 save slots
are fixed-size, so a 0-byte one always means damage.
⚠ The old `purge_truncated` self-heal is GONE with the two-way mode. Do not miss that the
protection moved to the source-side refusal rather than disappearing.

⚠⚠ **IT IS NOT A PIPELINE STAGE AND MUST NEVER BECOME ONE.** The user's first question on
seeing it was "is this going to run EVERY time a user does an install?" — it is a user-invoked
choice only. It is reached solely through the `install.sh` sub-command `case` (like
`collect`/`uninstall`, which `return`s before the stage machinery), and it is **deliberately
named `scripts/sync_saves.sh` with NO `NN_` prefix** — the first cut was `60_sync_saves.sh`
and that numeric prefix is exactly how it would end up in `STAGES` one day. Asserted by the
probe against `STAGES` and every profile stage list.

### ⚠⚠ THE SAVE TITLE-ID IS NOT THE DISC TITLE-ID (settled on-device 2026-07-28)

**Bloodborne saves under `CUSA00207/SPRJ0005`, while this dump's disc id is `CUSA03173`.**
Full path on the Deck:

```
$SHADPS4_USER_DIR/home/1000/savedata/CUSA00207/SPRJ0005/
    userdata0000 … userdata0010, backup0000, backup0010, sce_sys/
```

Confirmed 2026-07-28 by a throwaway `scripts/probe_savedir.sh` (deleted once it had answered;
it walked `$SHADPS4_USER_DIR` for real save slots and dumped the tree to `logs/`) and then by
real runs in both directions. If the layout ever needs re-checking, write that probe again
rather than guessing — a listing of `home/*/savedata/` settles it in one Deck trip. `CUSA00207` is Bloodborne's original id; the game keeps writing saves there
whatever the regional disc id. `SPRJ0005` is FromSoftware's project code. Both now live in
`deckborne.env` as `GAME_SAVE_TITLE_ID` / `GAME_SAVE_DIR_GLOB`.

⚠ **The layout has four decoys, and the first implementation fell for two of them.** Searching
for a directory *named after the title id* finds, in `sort` order:
`cache/CUSA03173` (the shader cache — **101 `.spv` files**), `custom_modules/CUSA03173`,
`download/CUSA03173`, `temp/CUSA03173`. There is also a top-level `savedata/` that is **empty**,
and `home/1001`–`1003` user slots that are empty. The original code picked `custom_modules`
(empty → "Exported 0 files", reported success), and once a shader cache existed it would have
picked *that* and exported 101 shader files as a save backup.

**The fix: discover by STRUCTURE, never by name.** Find directories containing real save slots
(`userdata####` / `backup####`), take their parent as the title dir, then choose by
`GAME_SAVE_TITLE_ID` → a `SPRJ*` child → the only candidate → otherwise **refuse and list**.
A cache or module folder can never be selected because it contains no save slots. The
DeckBorne side mirrors the emulator: `savefiles/<save-title-id>/<save-dir>/`.

⚠⚠ **exFAT ATE THE FIRST SUCCESSFUL EXPORT, AND THE RUN REPORTED SUCCESS.** 2026-07-28: the
sync found the right directory and copied all 15 files — and every file arrived **0 bytes**.
Directory entries flushed; data did not, because the stick was pulled. This is the *same*
failure as the 0-byte run logs (see "Logs dying on the USB"), which `finalize_log()` fixed with
`sync` — `sync_saves.sh` never had that call, and it hit the one thing here that cannot be
re-downloaded. Worse, while the two-way mode still existed the empty files carried a **newer**
mtime than the real save, so newer-wins would have imported them *over* it on the next run.
Guards now, all tested:
- **`sync`** after copying, so data is on the device before the stick can be pulled.
- **Post-copy verification** — every source file must exist at the destination, at the same
  size **and with a matching sha256**, or the run **dies** naming the files. It can no longer
  report success over truncation.
- **A damaged source is refused outright** (0-byte save slots), before anything is copied or
  even backed up. ⚠ This REPLACED a self-healing pre-pass that only made sense while both
  directions ran in one command; see the Export/Import section above.

⚠⚠ **SIZE CANNOT DISCRIMINATE TWO SAVES, SO THE COPY AND THE VERIFY BOTH RUN ON CHECKSUMS
(2026-07-29). Do not "optimise" the `-c` away.** Every PS4 save slot is *exactly* 1,310,720
bytes (or 262,144), so size equality between two valid saves is a CONSTANT, not evidence. That
left rsync's default quick check with only mtime to go on, and `verify_copy` checking a
proposition that could never fail:
- `copy_all` and `pending_changes` are `rsync -ac` / `-acn`, so a copy happens on content
  difference and "the two sides already match" is a checked claim rather than an mtime guess.
- `verify_copy` compares **sha256** per file (size first, for a cleaner `TRUNCATED` message),
  and reports `CONTENT DIFFERS` where it previously could not look.
- Falls back to size-only with a **loud warn** if `sha256sum` is absent, saying in the log why
  that is weak. The closing `Verified:` line names which check actually ran — never claim a
  checksum verify that did not happen.

**Demonstrated, not theorised:** with the old `-a`, a source and destination that shared a size
(always) and an mtime skipped **every real save slot** while printing *"Verified: every file
present at the destination at the same size"* and *"import complete"* — a total no-op reported
as success, in the one feature where that costs a save. Same fixture now copies all three slots
and passes a checksum verify.
⚠ The trigger needed an mtime collision, which is unlikely across two machines — this is
insurance, not a live bug. But exFAT stores mtime at **2-second** granularity against ext4's
finer stamps, and rsync compares with a 1-second window by default, so an exFAT↔ext4 seam is
the realistic route in. Third instance of this project's signature failure: the cheap check
proved a different proposition than the one being relied on.

**Cost measured, so don't refuse it on performance grounds:** on the real 15 MB / 15-file save
the whole script runs **0.57s** first export, **0.49s** no-op (dev box). The `-c` itself adds
~6-9ms; the sha verify ~170ms. On the Deck it re-reads 15 MB off USB instead of stat-ing it —
still comfortably sub-second against a run that already copies those bytes.

⚠ When verifying a save BY HAND, check entropy too — a real 1,310,720-byte slot gzips to
~418 KB, a zero-filled one to ~1 KB.

⚠ **IMPORT IS A MERGE, NOT A REPLACE** (measured 2026-07-29, expected behaviour — recorded
because it surprises). `src` is the **title** dir (`savefiles/CUSA00207`), not one save dir, and
there is no `--delete`. So an import brings over *every* `SPRJ*` folder and every slot inside
them, and **slots that exist only on the Deck survive**: importing a 3-slot save onto a 5-slot
Deck leaves slots 0-2 from the stick and 3-4 from the Deck, side by side. Nothing is lost (the
`.bak-<stamp>` holds the pre-import state) but the result is a blend of two machines rather than
a clean swap. Adding `--delete` would make it a true replace — and would also make a partial or
truncated stick copy able to **erase** Deck saves, which is why it is not there.

✅ **PROVEN ON-DEVICE 2026-07-28**, both the failure and the repair
(`logs/deckborne-saves-20260728-172226.log` then `-193349.log` on the stick), then **five more
clean runs** at 19:49–20:07, every one printing the `Verified:` line. Checked independently on
the stick rather than trusting the log: 15 files, 0 empty, 15 MB, sizes and mtimes matching the
Deck, and real entropy. ⚠ Those runs were the two-way build; the directional rewrite that
followed is verified off-Deck only.

Also verified off-Deck in an isolated root (`scratchpad/saves_probe.sh`, **44** checks) against
a replica of the real layout including all four decoys. The first case is the one that motivated
the rewrite: **an older save carried in from another PC, imported over a newer Deck save** —
it lands, and the Deck's save is backed up and recoverable. Plus: export as the exact mirror,
direction mandatory, both empty-source refusals, import onto a Deck that never saved, the
damaged-source refusal leaving everything untouched, no `.spv` ever copied, a full round trip,
a no-op run taking no backup while still verifying, a changing run still taking one, an import
onto a bare Deck not claiming a backup it never made, and that it is still not a stage.

✅ **BOTH DIRECTIONS PROVEN ON-DEVICE 2026-07-28.** `deckborne-saves-import-20260728-215531.log`
imported 5 files that were **older** than what was on the Deck — the case the old design could
not do — backing the Deck's newer save up first. The export nine seconds later copied 0 and
verified. A later pair at 22:04 both took the no-op path and left **no** backup dirs, confirmed
on the stick (`savefiles/` still 15 MB, nothing rewritten).
⚠ Testing trap hit while writing it: **`DECKBORNE_ROOT` is derived from `lib.sh`'s own location
and is NOT env-overridable**, so a probe that sets it and then runs `scripts/sync_saves.sh`
from the repo writes into the REAL repo. Invoke the copy inside the throwaway root instead.
⚠ Second probe-harness trap: a test that `chmod a-w`s a directory leaves it unremovable, so the
NEXT run's `rm -rf` half-fails and every later case inherits poisoned state. Restore permissions
recursively before deleting.

### ▶ NEW 2026-07-28: what the Deck actually reported back

First real Workshop session on hardware. Sources: `deckborne-run-20260728-160518.log`,
`-162655.log`, and `state-20260728-163803/shad_log.txt` (all on the stick).

- **The Workshop works end to end.** The 16:05 run read
  `/home/deck/.local/share/DeckBorne/settings.env` and forced FPS counter on, present Mailbox
  and pipeline cache on; the 16:26 run shows no settings file and fell back to profile values,
  so *Restore DeckBorne defaults* works too.
- **`Log.append` confirmed:** one `shad_log.txt` held **7** launches. Split on
  `Run: Starting shadps4 emulator` before attributing anything.
- **All 7 launches reconcile against the XML:** 30 FPS++ 291 = 3×97, 60 FPS++ 768 = 4×192,
  Resolution 1280x800 492 = 6×82, Optimal 1080p 76 = 1×76, light grids 12 = 6×2 and 2 = 1×2.
  So deck30 ×3, deck60 ×3, desktop ×1 — and the whole deckborne.env → stage 35 → XML → emulator
  chain is now proven for every target.
- **Pipeline cache failed a FIFTH time.** Forced on, and no `Preloaded N pipelines` line in any
  of the 7 launches. The loud stage-30 warning was right. Still: only that line proves success.
- **`Mailbox` looks genuinely supported, unlike `Immediate`.** Zero `FindPresentMode … falling
  back` lines across the whole log, and that line *is* emitted on fallback (four chocolate runs
  produced it for Immediate). ⚠ This is inference from a meaningful absence, not proof — it does
  NOT reopen the settled finding that Immediate is unavailable.
- **Mods:** revert-then-apply reconciled correctly (281 restored, 42 removed), 9 of 10 applied,
  5 mirrored into `-UPDATE`. The skip is `Bloodborne Reshaded`, which ships only
  `bloodbornereshadedv1.ini` — a ReShade config with no place in the game tree. The resolver is
  **right** to refuse it, but the message invites the user to fix something unfixable.
- ⚠ **The stick's `payloads/mods/` now holds 10–11 mods, not the three the table below lists.**
  That table is stale; read stage 40's applied list in the run log instead of trusting it.

**✅ FIXED 2026-07-29:** the run header (`lib.sh`, the `workshop  :` line) printed only
`gpu / fps-counter / hdr` — present mode and shader cache were added later and never got added,
so the 16:05 run's two overrides appeared *only* in the stage-30 line. It now prints all five
(`gpu / fps-counter / hdr / present / shader-cache`), verified by rendering both the all-`auto`
default and a forced `present=mailbox shader-cache=on`. ⚠ **Any new Workshop setting must be
added there too** — the header is a second place the schema is spelled out by hand, so it does
not follow `SETTINGS` in `user_settings.py` automatically.

### ▶ NEW 2026-07-28: UI polish batch (all verified off-Deck by rendering)

- **Only ONE bottom-row panel can be open** (`win.activePanel` + `openPanel()`), and **the
  button now toggles its own panel shut** (`togglePanel()`). Both panels open on hover and
  neither closes on hover-out, so before this they overlapped.
  ⚠ Two traps, both found by the probe and neither obvious:
  **`onClosed` fires AFTER the 120ms exit transition**, so stamping the close time there is too
  late — the tap that follows `CloseOnPressOutside` arrives first and re-opens. Stamp on
  `onAboutToHide`. And **`activePanel.opened` is false mid-transition**, so guarding the
  close on it lets both panels end up open on a fast switch; close unconditionally.
  A press on the button fires `CloseOnPressOutside` *and then* the tap — `togglePanel` absorbs
  that with a 200ms guard, which `openPanel` deliberately clears when switching panels.
- **`PanelScrollBar`: a Control resizes its `background` to the FULL control rect, ignoring the
  padding `contentItem` honours.** An 18px track sat behind an 8px thumb and read as a grey
  strip jutting out beside it. Pin `x`/`y`/`width`/`height` to `leftPadding`/`topPadding`/
  `availableWidth`/`availableHeight` — that also stops Qt resizing it.
- **`WorkshopPill` was a hard `implicitWidth: 52`**, so "Immediate" overflowed its box. Now
  `Math.max(52, label.implicitWidth + 20)` — floor kept so On/Off don't shrink to stubs.
- Copy: the save-sync completion message now names both directions and ends "Welcome back,
  revered hunter." on its own line (the panel text is already centred, so the blank line was
  the whole change); the Workshop scroll hint sits on its own line via `<br/>` and is **no
  longer underlined**; the GPU blurb ends "leave as the default."
  ⚠ `qml_probe.py` asserted the hint was underlined — that check now asserts the opposite.
  A test that pins old intent will fail the moment intent changes; fix the test, not the UI.

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

### ✅ FIXED: the UI Cancel button did not stop a relocation (found 2026-07-24, fixed by 2026-07-30)

**FIXED — verified in the code 2026-07-30.** `backend.py` now launches the pipeline through
`setsid`, so `install.sh` leads its own session, and cancel calls `os.killpg(pgid, sig)` instead
of Qt's single-pid `terminate()`/`kill()`. It reads `/proc` to confirm the group rather than
trusting that `setsid` ran. ⚠ Keep the mechanism below — it explains why the fix has to signal a
GROUP, and re-testing needs a genuinely slow copy (a tmpfs copy finishes inside the 2s window
and will pass a broken implementation).

The relocation code (`relocate_install` in `20_install_game.sh`) was itself correct:
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

### ✅ FIXED: relocation / profile-switch required `game-pkg/` (found 2026-07-24, fixed by 2026-07-30)

**FIXED — verified in the code 2026-07-30.** `00_preflight.sh:27` and `20_install_game.sh:18`
now both read `base_pkg="$(discover_base_pkg || true)"` behind an `if [ -n "$base_pkg" ]`, so the
dump is required only when something actually needs to be extracted. A relocation or a plain
profile switch on an already-extracted install no longer demands the ~30GB `.pkg` still be
present. ⚠ The fresh-install failure must stay intact: no install AND no `.pkg` still has to
`die` loudly.

The original analysis, kept because it explains the reasoning: the `.pkg` dump used to be a hard,
unconditional requirement — both stages `die`d on `discover_base_pkg` returning empty. That is
correct for a FRESH install (you can't
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

### ✅ ACCEPTED, NOT OPEN: deckborne needs a mod we cannot ship — this is by design

**Settled 2026-07-30 (user's call): "mod dependency is known and not an issue, it's part of the
build."** This is a documented property of the DeckBorne profile, not an unfinished item — do
NOT re-open it as a bug or "fix" it by gating `30 FPS++` on the mod being present. The
requirement is stated in `bootstrap.sh`'s next-steps output, the README's "Adding mods" section,
`payloads/mods/PUT-MODS-HERE.txt`, and the UI's community-mods row. ⚠ It used to be flagged here
as "the most user-facing unfinished thing in the repo" — that framing is retired.

The mechanics, which still matter: `30 FPS++` is safe in deckborne **only because** the vertex
fix is layered over it by stage 40. DeckBorne must not redistribute that mod
(`config/mods.catalog` explains why), so:

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

⚠ **STALE as of 2026-07-28** — the stick now carries **10–11** mods, not three. Kept only as a
reminder that the two sides differ; read stage 40's applied list in the run log for the truth.

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
**install-location picker** landed 2026-07-24 (above), **The Workshop** panel landed
2026-07-27 (above), and the **2026-07-28 UI polish batch** (single-active-panel + toggle-close,
the scrollbar fix, the pill width, the reworded save/scroll-hint/GPU copy). **None of it is
visible yet:**
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

1. **The Vulkan pipeline cache does not work on shadPS4 v0.16.0. FIVE consecutive
   failures** (the fifth 2026-07-28, forced on via the Workshop: no `Preloaded N pipelines`
   line in any of that log's 7 launches). The cleanest test: run 1 wrote a fresh `profile.bin` from this exact device
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
   ⚠ **`Mailbox` is a different story and appears to be SUPPORTED.** Forced on via the
   Workshop 2026-07-28 and the whole log contains **zero** `FindPresentMode … falling back`
   lines, where Immediate produced one every time. Inference from a meaningful absence, not
   proof — and it does **not** reopen Immediate, which stays unavailable. Nobody has reported
   how Mailbox *feels* yet; if it holds, it is the one lever that escapes Fifo quantization.

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

> **▶ ACTIVE WORK (2026-07-30): cut v0.8.0 "the Workshop update", then build the in-UI
> updater.** The items below are the standing backlog. The two deferred storage bugs and the
> mod-dependency hazard that used to head this list are all closed — see their sections above;
> do not re-open them.
>
> **Before the release:**
> - ✅ `build-release.sh` now excludes `savefiles/` **and** refuses to build if any
>   `userdata####`/`backup####` file survives into the staged tree. It packs the CURRENT folder
>   and is meant to run ON THE DECK, where a real save sits right there — without this it would
>   have published the builder's save data into a public GitHub release. The structural check is
>   the load-bearing half: a deny-list can miss, a `find` for save slots cannot.
> - ✅ `DECKBORNE_VERSION` (+ `DECKBORNE_REPO`) in `deckborne.env`, printed as the run header's
>   first line. ⚠ **This HAD to ship in 0.8.0**, not with the updater: the updater identifies an
>   install by this value, so any release without it is unidentifiable to every later updater.
>   Bump it at release time, matching the tag.
> - ✅ **The version shows bottom-right in the UI**, mirroring the artwork credit opposite it
>   (same `root` parent so it survives every view, same hide-while-a-panel-is-open rule).
>   `backend.py` PARSES it out of `deckborne.env` rather than shelling out — it is read at
>   construction, and an unreadable env must degrade to a blank label, never block the window.
>   ⚠ It handles BOTH spellings, `DECKBORNE_VERSION="${DECKBORNE_VERSION:-0.8.0}"` and a plain
>   assignment, because the env uses the `:-` idiom everywhere. `DECKBORNE_VERSION=x` in the
>   environment still wins.
> - ✅ **`docs/installer.jpg` regenerated** (1640×1033, the existing dimensions). The old one
>   dated 2026-07-26 and predated the Workshop entirely — its bottom row had two buttons, not
>   three — so it was already wrong for this release regardless of the version label.
>   ⚠ **Rendering it headlessly expands the Vanilla card whether or not `previewOpen` says so**
>   (a hover artifact of the offscreen render; a real user sees it collapsed). The shipped image
>   therefore shows Vanilla AND DeckBorne open. Harmless and arguably more informative, but do
>   not chase it as a UI bug — and if an exact match to the old framing is ever wanted, take the
>   shot on the Deck instead. Regenerate with `previewOpen=1` at 1080×680, scale the 2160×1360
>   grab to 1640×1033, save JPG q88 (≈157KB, matching the old file).
>   ⚠ Only `docs/installer.jpg` is referenced by README; the `*-attributed.jpg` pair are old
>   mockups and are not used anywhere.
> - ⏳ **The PR + tag are the user's** — never commit, push, or open a PR.
>
> **After v0.8.0 is published — the in-UI updater** (design settled 2026-07-30, user's call:
> "stage, then apply on relaunch"). A *Check for updates* `FootButton` in the Workshop footer,
> right of *Restore DeckBorne defaults*.
> - **Most of it already exists.** `bootstrap.sh` already downloads `DeckBorne.tar.gz` from
>   `/releases/latest/download`, verifies it with `tar -tzf`, and extracts over an existing
>   install — its own comments call re-running it a legitimate in-place update. The new
>   `scripts/update.sh` is that flow pointed at `$DECKBORNE_ROOT`, plus a version compare.
> - **The exclusions the user asked for are already free**, and by a stronger mechanism than an
>   ignore list: the tarball simply does not CONTAIN `game-pkg/`, `payloads/mods/`, `logs/`,
>   `payloads/shadps4/` or (now) `savefiles/`. ⚠ `payloads/patches` does not exist — patches live
>   in `$SHADPS4_USER_DIR/patches`, outside the tree. Workshop settings are in `$HOME` and are
>   untouched by construction.
> - ⚠⚠ **Three hazards, all from updating the tree you are running from:**
>   1. **The updater would overwrite ITSELF mid-run.** Bash reads a script incrementally, so
>      replacing it while it executes can run garbage. `bootstrap.sh` is immune only because
>      `curl | bash` feeds it from stdin. `update.sh` must copy itself to temp and re-exec.
>   2. **The AppImage is RUNNING.** The tarball contains `payloads/ui/*.AppImage` and the UI is
>      executing from it over a FUSE mount; `tar -x` truncates in place and would very likely
>      crash the UI mid-update. Extract to temp, swap the AppImage LAST by atomic `rename`
>      (leaves the open file undisturbed), then prompt to relaunch.
>   3. **exFAT.** Same family as the 0-byte logs, saves and AppImage: `sync` + verify after
>      extract, and check headroom for a ~90MB tarball plus its extraction.
> - ⚠ Clicking it on a DEV stick overwrites the working copy with the last release. Fine for
>   users, destructive for the author — warn, or gate it.

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

**A3. ✅ LANDED 2026-07-27 as "The Workshop"** — see the section of that name in "Current state".
GPU selection, the FPS counter and HDR are now user-settable, stored in
`$HOME/.local/share/DeckBorne/settings.env` (NOT deckborne.env — the reasoning is up there).
Auto is the default and is labelled "recommended"; an out-of-range index is now actively
refused by stage 30 rather than merely warned about. **What remains of this item:** more
settings, if any are wanted, and on-device verification. The original note follows for its
reasoning, which still applies to anything added next.

**A3 (original note). GPU selection becomes a real UI control (planned 2026-07-25).** Part of
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
