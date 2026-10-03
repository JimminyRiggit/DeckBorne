# CLAUDE.md — working notes for DeckBorne

Read `README.md` first for what the project *is*. This file is the stuff that isn't
obvious from the code: hard-won facts, traps, and what's left to do.

> **▶ Resuming a session? Jump to [Current state](#current-state--read-this-first-to-resume).**

**Map of this file:** The setup · Steam facts · Code traps · Testing tile behaviour ·
**Current state** (open items) · Profiles and targets · Feature notes · Deck hardware facts ·
The warm-up · Steam restarts · What comes next · Conventions.

## The setup (matters more than it sounds)

- **The dev box is `aarch64`. The Deck is `x86-64`.** The emulator and the PKG
  extractor **cannot be run here**. Anything about whether the game boots, whether a
  tile appears, or how Steam behaves has to be tested on the Deck.
- **The USB stick is the deployment target, not the source.** Edit files in this repo,
  then copy to the stick's `DeckBorne/` directory. ⚠ The volume label is **RuhRoh**
  (`/run/media/<user>/RuhRoh/DeckBorne/`), exFAT. Never author on the stick.
  **Sync with `rsync --checksum`, excluding `logs/`, `savefiles/`, `game-pkg/`,
  `payloads/mods/`, `payloads/shadps4/` and `payloads/ui/`** — those are user data or
  Deck-built, and the stick's copies are the only ones. exFAT corrupts on unflushed pulls;
  `sync` before the stick is removed.
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
   argv** — which is what makes `pkill -f` on it so dangerous (see "The warm-up").
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
- ⚠⚠ **`shortcuts.vdf` KEY CASING IS STEAM'S, AND THE ADD/UPDATE PATH READ IT
  CASE-SENSITIVELY — every install shipped users a BROKEN HEADLESS TILE.** Fixed
  2026-08-02. `shortcut_entry()` writes `appname`; **Steam rewrites the file on exit and
  normalises the key to `AppName`**. The matcher was `v.get("appname") == args.name` — an
  exact lookup that returns `None` for every entry in a Steam-touched file — so `idx`
  stayed `None` and the "update" **appended a duplicate** instead.
  Consequence, and it is the worst possible one: stage 50 writes headless gamescope
  options, starts Steam, warm-launches, then stops Steam — **that stop is exactly when
  Steam re-cases the file** — so the restore write at `:508` ALWAYS appended instead of
  updating. The real tile (correct appid, **carrying the artwork**) kept
  `gamescope --backend headless`, and a second art-less "Bloodborne" tile appeared beside
  it. The user clicks the one with the capsule art, the game runs into a headless
  compositor: **audio plays, no picture, Big Picture spins on the Deck logo forever.**
  And stage 50 printed `✓ Tile restored — now launches Bloodborne normally.`
  ⚠ **The proof was a natural control in one user's `collect`**: `userdata/0` (which Steam
  never loads, so the keys stayed lowercase) had ONE correct entry, while
  `userdata/<real>` from the same install had the headless tile plus a duplicate. Same
  code, same run, one variable. Keep that trick — a Steam-untouched userdata dir is a free
  control for anything casing-related.
  Fix: match via `_field()` (case-insensitive) **and** by normalised `Exe`, prefer the
  candidate whose stored appid equals ours, update it in place, and **collapse the rest**
  so already-broken users self-heal on the next install. Plus `_verify_written()` — a
  read-back asserting exactly one entry with our appid holds the options we just wrote;
  it returns 1 so stage 50's `else` branch fires instead of lying.
  ⚠ Same family as the uninstall's `v.get("Exe")` bug directly above — **that one was
  fixed with `_field()` and the add/update path never got the same treatment.** When you
  fix a casing bug here, grep for every other raw `.get(` on a vdf entry.
  ⚠ `--remove`'s two `print` statements had the same raw `v.get('appname')` and were
  logging `None` for Steam-cased entries. Fixed at the same time; cosmetic only.
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
- **The release tarball's exec bits came from WHEREVER IT WAS BUILT** (fixed 2026-09-29). A
  user extracted the tarball, `DeckBorne.desktop` was not executable, Plasma asked "open
  with…", they picked a text editor and KDE remembered it (`application/x-desktop` in
  `~/.config/mimeapps.list`) — so it kept opening in the editor even after `chmod +x`.
  `DeckBorne.desktop` had been `100644` in git **since the initial commit**, along with
  `35_apply_patches.sh`, `user_settings.py`, `patch_config_json.py`, `ui/main.py`. Earlier
  releases only worked because they were built off the exFAT stick, where every file reads
  as `0755`; a build from an ext4 git checkout shipped git's modes. `bootstrap.sh` and
  `update.sh` both `chmod` after extracting, so only the **direct-extract** path (README's
  USB method) was exposed. Fixed three ways: the git modes; `build-release.sh` normalises the
  staged tree (dirs 755, files 644, then `*.sh *.py *.desktop *.AppImage` 755) so the
  builder's filesystem no longer matters, and **refuses to build** unless `tar -tv` shows
  the `.desktop`, `run.sh`, `install.sh`, `uninstall.sh` and the AppImage as executable
  (verified to fail with normalisation removed); and the `.desktop` now runs
  `exec bash …/run.sh`, so `run.sh` needs no exec bit of its own.
  ⚠ `desktop-file-validate` rejects the `Exec=` line (single quotes, bare `$`). So did the
  original; KDE accepts it and it is proven on-device. Don't "fix" the quoting without a
  Deck to test on.
  ⚠ Nothing we ship can fix a **FAT32** stick: udisks mounts vfat with `showexec`, so no
  `.desktop` there is ever executable and `chmod` cannot change that. exFAT is fine.
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

*(Pruned 2026-10-03. The long-form history — verification narratives, probe counts, the UI
build saga, resolved investigations — is in git: `git log -p -- CLAUDE.md`, and
`git log --all -- HANDOFF.md` for the pre-07-19 notes.)*

**The pipeline is done and proven on-device** front to back: install, extract, config,
patches, mods, Steam tile + artwork, Recent Games, uninstall, relocation, saves, the
Workshop, and the in-UI updater. Remaining work is tuning, polish and the open items below.

**Version `0.8.5.1`** (`config/deckborne.env`). There is no separate UI version —
`backend.py::_read_version()` parses that same file. Bump it at release time, matching the
tag. The PR and tag are the user's.

### ▶ Open — uncommitted work in the tree (2026-09-25 → 09-30)

1. **Patch renames + empty-patches-dir brick (2026-09-25), fixed — proven on-device 10-03 (see 2).**
   Upstream `ps4_cheats` renamed `Disable Motion Blur (perf increase)` → `(Perf Increase)`,
   `Model LOD 1 (Lower)` → `(Lower model detail)`, `Model LOD -2 (Highest)` →
   `(Highest model detail)`, so stage 35's name check failed for every profile. Stage 35
   had already `mkdir`'d the patches dir, leaving it EMPTY — and **shadPS4 v0.16.0 parses
   `<repo>/files.json` with no existence check and no try/catch**
   (`memory_patcher.cpp:200-201`), so an empty `patches/shadPS4/` terminates the emulator at
   boot. "No patches" is harmless; an empty dir is fatal. The no-network and empty-download
   paths had the same brick. Fix: new names in all five `PATCHES_*` strings; no early
   `mkdir`; `prune_unusable_patch_dir` on entry and every failure exit (a non-empty dir
   without a valid `files.json` is MOVED to `patches-disabled/`, never deleted — it may be a
   user's own set); `files.json` written BEFORE the xml.
   ⚠ Upstream `main` has since added the guards. Do not read current source and call this
   over-defensive — v0.16.0, the shipped AppImage, is what crashes.
   ⚠ The uninstall does not remove the patches dir; stage 35's self-heal on entry is what
   clears a poisoned one.
2. **0.8.5.1 hotfix (2026-10-03): patches are now PINNED to an upstream commit.** Upstream
   renamed `Skip Intro` → `Skip Intro + warning message` on 10-02, a week after the 09-25
   fix, unpatching every DeckBorne target again. `PATCHES_URL` now builds on `PATCHES_REV`
   (`28583f6…`, upstream's 10-02 commit) instead of `main`. All five `PATCHES_*` sets
   resolve and are address-clash-free at that revision.
   **Write counts at the pinned rev:** `30 FPS++` **135**, `60 FPS++` **245**,
   `Resolution Patch 1280x800` **98**, `Optimal 1080p` **92**, `Skip Intro + warning
   message` 4, light grids 2, LODs 1. (July was 97/192/82/76; 09-25 was 159/285.)
   ✅ **PROVEN ON-DEVICE 2026-10-03, deck30** (`logs/deckborne-run-20261003-083135.log`,
   launch #25 in `state-20261003-084059/shad_log.txt`): fetched from the pinned URL, all 11
   enabled, every write count above matched exactly, dmem 4000, loaded `m24_01` (one `.btl`
   open — no 09-30 loop) and `m27_00`, saved normally. `deck60`/`desktop` at this rev are
   still unplayed.
   ⚠ That session ended `SignalHandler: Unreachable code!` + `Unhandled access violation`
   — **on the user's Steam → Exit game**, after the save completed. A SIGKILL cannot log
   anything (earlier exits simply stop mid-log), so this is a segfault during shutdown
   after Steam's SIGTERM. Judged harmless. If it ever appears WITHOUT a user exit, suspect
   the new `30 FPS++` content first and A/B against vanilla.
   Same hotfix: stage 35 no longer leaves the PREVIOUS profile's patches enabled on
   failure. Offline, it re-applies the new profile to the copy already on the device. When
   the apply/verify fails, `disable_stale_patches` sets every `isEnabled="false"`. Before,
   an offline DeckBorne → Vanilla switch kept `30 FPS++` on while stage 40 removed the
   vertex mod.
   **⚠ TODO — THIS NEEDS TO SCALE.** Pinning stops the bleeding, but a bump is a manual
   chore (pick a rev, re-check every name, re-count, re-clash-check), and we fall behind
   upstream fixes. Options to weigh: match patches by a stable key (address/content) or a
   name alias table instead of exact `Name`; a script that diffs a candidate rev against
   our sets and prints renames + write-count deltas; a CI check that flags upstream drift;
   or a per-patch fallback so one missing name skips that patch instead of all of them.
3. **Release tarball exec bits** (2026-09-29) — see the Code-traps entry. Fixed in git
   modes, `build-release.sh` normalisation + refusal, and the `.desktop` Exec line.
4. **0-byte mod files → infinite load after character creation (2026-09-30).** exFAT
   unflushed writes left three mods (`Bloodborne FPS Boost`, `Pointlight Removal`,
   `Bloodborne Reshaded`) entirely 0-byte; stage 40 merged them over real game files and
   printed `✓ applied`. Symptom in `shad_log.txt`: tens of thousands of open/close of
   `map/m24_01_00_00/m24_01_00_00_0000.btl.dcx`. The user re-copied the mods (0 empty files,
   all `.dcx` carry `DCX` magic); not yet reinstalled/played. Recovery needs no re-extract —
   reinstall, and revert-first restores originals from `.pre-mods`.
   **TODO: stage 40 has no empty-file guard.** Refuse a mod that would replace a game file
   with a 0-byte one (the `sync_saves.sh` rule).
   Pointlight Removal is a byte-identical subset of FPS Boost — redundant, not conflicting.

### ▶ Open — longer-standing

- **`build-release.sh` has no structural guard against user-diagnostics bundles.** A user's
  `*_logs.tar` (Steam ID, `shortcuts.vdf`, sysinfo) once sat in the repo root and would have
  shipped; the deny-list catches `logs/`/`savefiles/` but not a tarball, zip or stray
  `state-*/`. Add a structural refusal like the save-slot check.
- **Never run on hardware:** the `shortcuts.vdf` duplicate-collapse self-heal (needs an
  already-broken user installing over the top), and the updater's `restartApp()` relaunch
  (needs a published release newer than the stick — publish, then set the stick one
  version back for a run).
- **`steam -shutdown` is ignored on this Deck.** `steam_stop` survives it by polling after
  SIGTERM; why SteamOS ignores the IPC is unknown — the captured stderr is where to start.
- **Unreported:** the 30-FPS *feel* of any profile (nobody has reported pacing), how
  `desktop` looks/holds 60 on real desktop hardware, and how `Mailbox` feels.
- **AppImage on the stick lags `ui/`.** Every `ui/` change needs `./ui/build-appimage.sh`
  **on the Deck** (arch-specific; dev box is aarch64). `scripts/`/`config/` need no rebuild.
- **The stick is UNGUARDED against a dev update** — its `CLAUDE.md` was deleted 2026-08-03.
  Put one back if you want `update.sh`'s dev guard on it.

## Profiles and targets

**Three profiles:**
- **`vanilla`** — the shipping default. 7 patches, no frame-rate patch, no mods (stage 40
  *reverts* mods), `extra_dmem` 2000, HDR off, FPS counter off. "Vanilla" means stock game
  files and the game as it shipped — keep additions out of it. Still keeps Model LOD 1 + FSR.
- **`deckborne`** — vanilla's patches + `30 FPS++`, `Skip Intro`, `Disable Chromatic
  Aberration`, `Disable Motion Blur`; `extra_dmem` 4000; HDR permitted; **hard mod
  dependency** (below).
- **`chocolate`** — dev/staging lane, CLI-only, patch set identical to deckborne; the only
  profile with the FPS counter on. Changes reach deckborne by promotion.

**deckborne has three TARGETS** (`DECKBORNE_TARGET`, chosen by pills on the UI card):
`deck30` (default, = unset), `deck60`, `desktop` (60 FPS · 1080p).
- **A target, not a profile — load-bearing.** All three run the identical stage list, which
  keeps install.sh's `@@DBUI STAGE <idx>` markers aligned with `STAGES_DECKBORNE` in
  `backend.py`. Only stages 30 and 35 read it. Validated in install.sh AND both stages (a
  single-stage run bypasses install.sh).
- `desktop` swaps both resolution-keyed patches (`1080p Light Grid`, `Optimal 1080p`),
  `Model LOD -2 (Highest model detail)` for LOD 1 (same address `0x0216fc09` — swap, never
  both), `extra_dmem` 6000, FSR off. Motion blur/CA stay disabled (user's call — QOL, not
  perf).
- ⚠ **There is no `Resolution Patch 1920x1080` upstream** — the 16:9 ladder skips 1080p.
  `Optimal 1080p` is the only 1080p render patch. Don't go looking again.
- `60 FPS++` renders clean with the vertex mod; it reverted on the Deck for **performance
  only**. Don't re-litigate it as broken.

**The FPS++ mod dependency is accepted, by design** (user's call 2026-07-30). Every
deckborne target is FPS++ family and artifacts (vertex explosions) without the Nexus
vertex-explosion fix, which we must not redistribute (`config/mods.catalog`). Documented in
bootstrap, README, `PUT-MODS-HERE.txt` and the UI. Do NOT re-open it as a bug or gate
`30 FPS++` on the mod.

**Per-target keys must be written by EVERY profile/target** (see the Code trap on
`config.json` leaking). `GPU.hdr_allowed`: true for deckborne/chocolate, **false (written,
not omitted)** for vanilla — it's a permission ANDed with a real capability query, and
Bloodborne never requests HDR anyway; it's on so an HDR mod isn't blocked.

**⚠⚠ `Vulkan.gpu_id` — do NOT build auto-detection.** With `-1`, shadPS4 v0.16.0 already
sorts devices by (Vulkan 1.3, discrete, largest heap) and picks the winner. A `>=0` index
indexes raw `vkEnumeratePhysicalDevices` order, and out-of-range is a **fatal assert**.
`scripts/detect_gpu.py` only *reports*/predicts; stage 30 `--validate`s a forced index and
falls back to `-1` if out of range. Only `vulkaninfo` gives Vulkan order — `lspci`/sysfs
lists are not indices and must never be selectable.

**Levers not yet pulled** (clash-checked, additive): `Disable Dynamic Light Shadows`
(biggest expected win), `Disable SSAO`, `Disable DoF`, `Disable AA`, `Model LOD 2 (Lowest)`
(alternative to LOD 1, never both). On a Deck go lower LOD, not higher.
`Performance Patch (perf increase)` stays excluded — it clashes with four set members.

## Feature notes (what's non-obvious about each)

### The Workshop — user emulator settings

- **Store is `$HOME/.local/share/DeckBorne/settings.env`, NOT `deckborne.env`** (git-tracked,
  on corruption-prone exFAT, clobbered by updates, stick may be absent). Don't consolidate.
- **Precedence `env > Workshop > shipped default`** falls out of `load_env` sourcing
  settings.env first with the same `${VAR:-}` idiom. `load_env` therefore repeats the
  `DECKBORNE_STATE_DIR` default — change one, change the other.
- Only non-default values are written; all-defaults deletes the file. Uninstall keeps it.
  Settings apply on the next install (a profile switch re-runs stage 30).
- Variables: `VULKAN_GPU_ID`, `DECKBORNE_FPS_COUNTER`/`_HDR`/`_SHADER_CACHE` (`auto|on|off`),
  `DECKBORNE_PRESENT_MODE` (`auto|fifo|mailbox|immediate`). Resolved after the profile
  `case`; unknown values die.
- **⚠⚠ No "Auto" pill, but `auto` is still what's stored.** The highlighted option is what
  `auto` resolves to; **clicking the highlighted option stores `auto`, not the literal** —
  otherwise a tap silently pins the setting and profile switches stop moving it. Same for
  GPU (stores `-1`, never the index). What `auto` resolves to is read from `deckborne.env`
  (`user_settings.auto_values()`), against the DECKBORNE profile — so HDR highlights "On"
  even though vanilla will write false. Known, accepted.
- Present mode and shader cache are exposed despite being settled-negative on the Deck
  (user's call); stage 30 warns loudly when forced. Not a reopening of those findings.
- `scripts/user_settings.py` is the schema's single source of truth; pill rows are
  schema-driven. **But the run header in `lib.sh` (`workshop  :` line) spells settings out
  by hand — add any new setting there too.**
- Lives in `scripts/`, not `ui/`, so it's fixable from the USB without an AppImage rebuild.
  Same reason for `detect_storage.py`, `check_update.py`.

### Workshop / storage panel UI traps (`Main.qml`)

- **Panels drop DOWN and fill to the window bottom.** An upward-opening version was rejected
  — don't reintroduce it. Storage sizes to content and only caps at that edge.
- **`dropHeight` binding has a deliberate dummy dependency** (`reflowDeps`) — `mapToItem()`
  doesn't re-evaluate on its own. Don't "clean up" the unused variable.
- **Footer is pinned OUTSIDE the Flickable** and overlays it with a **vertical** fade
  gradient. Don't restore a horizontal one (reads as a bar). `contentHeight` must include
  `footer.height + 4`.
- **`PanelScrollBar` is an anchored sibling, not `ScrollBar.vertical`** — the attached form
  sets height imperatively from C++ and destroys any height binding, so the thumb slid under
  the footer button. Drive it from `visibleArea` manually.
- A Control resizes its `background` to the full rect ignoring padding — pin the
  scrollbar background's geometry to the padding values.
- **Only one panel open** (`win.activePanel`); the button toggles its panel. Stamp close time
  in `onAboutToHide` (`onClosed` fires after the 120ms transition); close unconditionally
  (`.opened` is false mid-transition).
- **Art credit lives in each panel's footer**; the window's Snatti89 credit hides while a
  panel is open (`win.openPanels`). A single swapping credit was rejected — don't bring it
  back. Credit names/URLs are properties at the top of `Main.qml`.
- **Panel art must be `.jpg`** — `build-appimage.sh` stages `art/*.jpg` only; a `.jpeg`
  would silently vanish on the Deck.
- **Don't add `QtQuick.Effects`/`MultiEffect`** — a QML import missing from the AppImage
  means the UI doesn't start at all, Deck only.
- **Footer slack is ~113px** (Workshop footer: credit + status + two buttons). Any new status
  string must fit; check by rendering.
- `win.footerBand` (44): anything anchored to the window bottom must clear the strip the
  credit and version label own.
- The storage dropdown closes on a 220ms delay and also toggles on tap (Game Mode has no
  hover). A full-width "INSTALL LOCATION" section above the cards was rejected — the home
  view is three cards then one bottom row.
- OptionCard: a card with a `footer` is not clickable (the pills start the run); `tapOpen`
  lets touch expand it.
- Stage rows in `backend.py` are index-aligned with `@@DBUI STAGE <idx>`. Row text is free;
  adding/removing a row shifts every later stage.

**Testing the UI:** verify by RENDERING (`ui/main.py --shot`, `--open 8` Workshop, `--open 9`
storage), not by walking the object tree — Repeater delegates aren't in `children()`, and
shiboken wrappers fail on `QQuickItem*` (`mapToItem(None…)`, `property("parent")`). For
geometry use `QQmlProperty.read` after finding by `metaObject().className()`. Panels need a
window taller than 680 to render the footer. Reading a QML enum from Python raises
`Can't find converter`; an exception in a `QTimer` callback hangs the probe — `app.exit()`
from the handler. Headless renders expand the Vanilla card regardless of `previewOpen`.

### Install location (SD card / USB)

- **Only `GAMES_DIR` moves; `APP_DIR` stays in `$HOME` — load-bearing.** The tile's `Exe`
  is in `APP_DIR` and `grid_appid()` hashes it; moving it changes the appid and strands
  tiles from `--by-exe` uninstall.
- `scripts/detect_storage.py` is the source of truth. exFAT/NTFS/vfat are **refused** (case-
  insensitive), listed dimmed with the reason. Unlabelled cards show as `SD card`, not UUID.
- Resolution `env > remembered (`$HOME/.local/share/DeckBorne/storage_root`) > $HOME`. A
  remembered root is **never existence-checked at load** — card out means keep pointing at
  it. Uninstall forgets it only if the root itself exists (not merely the games dir gone).
- Only the INSTALL path passes `DECKBORNE_STORAGE_ROOT`; uninstall/collect act on where the
  game is. Default selection is the root filesystem unless a device already holds the game.
- **Switching devices relocates instead of re-extracting** (stage 20): copy → verify (regular
  files only: count + bytes; directory `st_size` is fs-dependent) → swap → delete source.
  Moves `<title>`, `-UPDATE` and `.pre-mods` only — never the whole games dir. Refuses to
  guess between two installs. `DECKBORNE_NO_RELOCATE=1` forces extract.
- **Stage 50's skip check compares stored LaunchOptions** (`--expect-launch-options`) so a
  relocated install rebuilds the tile. Without it the tile pointed at the deleted path.
- `game-pkg/` is only required when something must be extracted.
- UI cancel signals the process GROUP (`setsid` + `os.killpg`); Qt's `terminate()` only hits
  install.sh's pid and orphans the copy. Re-test cancel with a genuinely slow copy.

### Saves — Export / Import (`scripts/sync_saves.sh`)

- **Never a pipeline stage, and never `NN_`-prefixed.** Reached only via `install.sh
  saves-export|saves-import`; a bare `saves` dies.
- **⚠⚠ No timestamp comparison — restoring "newer wins" is a regression.** A save carried in
  from another machine is usually OLDER; mtime doesn't express intent, the click does.
  Unconditional `rsync -ac` in the chosen direction.
- **Save path is `home/1000/savedata/CUSA00207/SPRJ0005/`, not the disc id `CUSA03173`.**
  Discover by STRUCTURE (dirs containing `userdata####`/`backup####`), never by name —
  `cache/`, `custom_modules/`, `download/`, `temp/` all carry the disc id and are decoys.
- Guards: refuse a source with any 0-byte slot (before copying or backing up); `.bak-<stamp>`
  of the destination only when the dry-run shows changes, and `backup_side` returns 0 only if
  the backup really exists; `sync`; **sha256 verify**. Size can't discriminate saves (slots
  are fixed-size), so don't drop `-c` or the checksum. Hand-check: a real slot gzips to
  ~418 KB, a zeroed one ~1 KB.
- **Import is a merge**, no `--delete` (a truncated stick copy must not erase Deck saves).
- Probe trap: `DECKBORNE_ROOT` derives from `lib.sh`'s location and isn't env-overridable —
  run copies inside the throwaway root.

### Mods (stage 40)

- Every profile runs stage 40. vanilla reverts; deckborne/chocolate **revert first, then
  apply**, so a removed mod doesn't linger. `.pre-mods` backups are **first-write-wins** —
  they always hold the original extraction's bytes, which is what makes switching safe.
- The resolver finds nesting depth and anchor by asking the installed game "do these files
  exist under you?"; refuses multi-variant and unmatched mods; ambiguity keys on where bytes
  LAND. Cost: two passes (names only when files are inconclusive).
- **`-UPDATE` shadow is mirrored** (`DECKBORNE_MOD_SHADOW=mirror`): a mod file also present in
  `-UPDATE` is copied there too, update original backed up; revert restores it.
- **Locale trap:** this dump is EU (`menu/enggb`); most menu mods ship `engus`.
- Stray top-level files in a mod get merged (and removed on revert) — left alone deliberately.
- **Exclude `payloads/mods/` when syncing to the stick** — the stick's set differs from the
  repo's and is the user's.

### In-UI updater (`scripts/update.sh`, `scripts/check_update.py`)

- Lives in `scripts/` so a broken checker can be fixed without an update. Every check appends
  to `logs/update-check.log`. Reached only via `install.sh update` — never a stage.
- Hazards and how they're handled — **don't regress any**: `update.sh` re-execs from a temp
  copy; files are placed via `rsync -a`/copy-then-rename because **`install.sh` is itself
  running** (an in-place `cp` fed bash garbage); the running AppImage is swapped by **double
  rename** (`.outgoing-<stamp>`), never overwritten — exFAT has no inode refcounting.
  `sync`, `tar -tzf`, and post-apply verification throughout.
- Full tarball, deliberately (~95 MiB, ~5 s); split assets were measured and rejected.
- **⚠⚠ Forward-only by design. DO NOT add a downgrade guard.** `--force` exists for testing.
- Dev guard refuses a tree with `.git/`, `CLAUDE.md` or `.venv-ui/`. `.gitignore` is not a
  marker (excluded from the tarball now, but don't key on it).
- User data is preserved by construction (not in the tarball) plus `SKIP_TOP`/`SKIP_PAYLOAD`.

### Other behaviour worth knowing

- **Profile switches are cheap:** stage 20 skips a complete extraction
  (`DECKBORNE_FORCE_EXTRACT=1` overrides); stage 50 skips when tile + artwork + launch options
  match (`DECKBORNE_FORCE_TILE=1`).
- **Fatal errors reach the UI** via `die` → `@@DBUI ERROR`; `backend.py` keeps the FIRST one.
  `@@DBUI STATUS` overrides a stage's message (used by relocation).
- **Stay-awake:** suspend (`systemd-inhibit`) and screen-blanking (held D-Bus
  ScreenSaver/PowerManagement inhibit) are **different mechanisms** — both are needed, and
  one-shot `dbus-send`/`gdbus`/`busctl` are useless (released on disconnect). Watchers release
  on flag-file removal or installer death. `DECKBORNE_KEEP_AWAKE=0` opts out.
- Quotes rotate from a shuffled bag (no repeats per cycle).
- `steam_start` scope units are `app-steam-$(date +%s%N)` — unique per call (stage 50 calls it
  twice) and **one dash segment** so the portal still reads app-id `steam`.
- `config.json` is not evidence; `shad_log.txt` is. With `--log-append` it holds a whole
  session — split on `Run: Starting shadps4 emulator` before counting patch writes.
- Check run logs for `No matching update .pkg found` before trusting a perf report — without
  the v1.09 update no patches apply.

## Deck hardware facts (settled — do not re-litigate)

1. **The Vulkan pipeline cache does not work on shadPS4 v0.16.0** — five consecutive
   failures. A `profile.bin` written on this device was rejected 20 minutes later
   (`WarmUp: Pipeline cache isn't compatible with current system.`). Off by default; leaving
   it on writes hundreds of unread files per launch with no eviction. Re-test only after a
   shadPS4 update, and only trust a `Preloaded N pipelines` line.
2. **`present_mode=Immediate` is unavailable** — the driver doesn't advertise it; shadPS4
   logs `FindPresentMode … falling back to Fifo`. Under Fifo, presentation is quantized
   (60/30/20/15), which explains the old "~45 FPS with judder" report. shadPS4 accepts only
   `Mailbox|Fifo|Immediate`. **`Mailbox` appears supported** (no fallback line when forced) —
   inference, not proof; nobody has reported how it feels.

**Where truth lives:** `config.json` is not evidence of what the emulator does —
`shad_log.txt` is. Fallbacks are logged, not silent.

## The warm-up (stage 50) — was a desktop-lockout bug, now fixed

Stage 50 launches the tile once (`steam://rungameid`) so it lands in Recent, then kills it.
The old `pkill -f <AppImage path>` matched Steam's `reaper` and the AppImage runtime but
**not the game** (AppRun runs from `/tmp/.mount_XXXX/` without the path in argv). Killing
reaper tore down Steam Input (face buttons dead, mouse alive) while the game kept the
screen fullscreen — only a reboot recovered. The log said "complete ✓" regardless.

**The fix — keep all three layers:**
- `stop_warmup()` finds reaper **by appid**, kills its descendants by ancestry deepest-first,
  **never reaper** (except as a last resort after the game is confirmed gone), and verifies
  via `_pid_alive()` (reads `/proc/<pid>/stat`; `kill -0` succeeds on zombies).
- The warm-up runs under **headless gamescope** (`--backend headless -- %command%` in
  LaunchOptions, then restored). The restore is load-bearing — an `EXIT` trap writes plain
  options if interrupted. Falls back to visible where headless gamescope isn't available.
  `DECKBORNE_WARMUP_HEADLESS=0` disables it — and then stage 50 has no restore step, so Steam
  stays in its `-silent` (invisible) state. Not the Deck default.
- Under headless, `_reaper_pid` actually matches gamescope (its argv contains the reaper
  string). Behaviour is correct; the `reaper=` log label is just mislabelled.

It was intermittent (~2–3 in ~8), and has been clean since 2026-07-17; the run now prints
`WARM-UP LEFT PROCESSES RUNNING` with pids if it ever regresses. `DECKBORNE_WARMUP=0` skips
the warm-up entirely.

**Process-handling rules this taught:**
- **Never `pkill -f`** — it matches the shell running it too. Kill by pid.
- Read `/proc/<pid>/cmdline` as `cat … 2>/dev/null | tr …` — a redirect on `tr` doesn't
  suppress the shell's own open error for a vanished pid (`_proc_cmdline()`).
- Never verify a process by a single name match (reaper vs game, zombie vs alive, launcher vs
  client). This is the project's recurring footgun.

## Steam restarts — how they work now (don't re-break)

- User-facing restarts go through `steam_restart_visible()` (both stage 50 and uninstall):
  wait for `steam`, settle, confirm `steam` + `steamwebhelper`. **No `-silent`** there — on
  this KDE desktop `-silent` goes to a tray icon that never surfaces. `-silent` is only for
  the warm-up's transient restart.
- `steam_start` launches `setsid systemd-run --user --scope --unit=app-steam-<id> -- steam`:
  the `.scope` keeps the portal identity (Steam fact 7), `setsid` keeps it alive after the
  script exits. A `--user` service survived but lost portal identity (screen-share prompt
  every run); a plain scope died with the script.
- Uninstall keeps Steam stopped for the whole run and restarts at the END.

## What comes next (backlog, roughly by value)

- **A. Steam's final restart steals focus from the installer UI.** User wants it fixed, not
  now. Visibility is the FLAGS argument to `steam_start`, independent of the scope mechanism;
  options are re-raising the installer after the restart or a KWin rule. Must not regress
  "Steam survives + portal stays quiet".
- **A2. desktop target on real desktop hardware** — confirm it holds 60 at 1080p and decide
  if anything else should un-invert.
- **B. Steam back silently** (tray) — a separate SNI investigation.
- **Bank more clean stage-50 runs**, then retire `DECKBORNE_PROBE`.
- **Narrow the `collect` snapshot** — it copies all of `localconfig.vdf` (auth tickets) onto
  a USB stick; only `Software/Valve/Steam/apps` is needed.
- **Stranded legacy records** — orphaned `2360460574` entries in the user's
  `localconfig.vdf` from an old appid formula; a `--purge-appid <id>` flag would clear them.
  Don't carry a legacy-hash sweep forever.
- **Close the skipped control** for the mod fix: `40_apply_mods.sh --revert`, play, confirm
  artifacting returns, re-apply. Only matters if something downstream looks wrong.

## Conventions

- `config/deckborne.env` is the single source of truth for versions, checksums, paths,
  IDs. Values there, not inline. Env-overridable where it helps testing.
- Shell scripts source `lib.sh` then `load_env`; use `step`/`ok`/`warn`/`die` for
  output so it lands in the run log consistently.
- Cleanup and best-effort niceties (warm-up, play-record purge) must **never** fail an
  install or uninstall — catch, warn, continue.
- Anything destructive gets a backup (`*.deckborne.bak`) and an atomic write.
