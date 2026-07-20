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
  ⚠ **TRIMMED to 8 patches 2026-07-19:** `Skip Intro` and `Disable Motion Blur` were dropped
  (presentation choices, not compatibility fixes — the promotion had swept them in from
  chocolate unexamined). They stay in deckborne. This set is a SUBSET of the proven 10, so it
  cannot reintroduce the artifacting, but **it has not itself run on-device** and losing
  `Disable Motion Blur` makes it marginally heavier than what was measured — if pacing looks
  worse than the 2026-07-19 run, that is the variable. ⚠ Still not literally stock: it keeps
  no chromatic aberration, Model LOD 1 and FSR upscaling.
- **`deckborne`** — the tuned experience: vanilla + `30 FPS++`, **and a HARD MOD
  DEPENDENCY** (below). No longer frozen — it was promoted, deliberately.
- **`chocolate`** — the DEV/STAGING lane. Currently **identical to deckborne** (its config
  was just promoted wholesale), so it is a free experiment slot again.

`chocolate` is CLI-only; `ui/backend.py` offers only vanilla and deckborne, deliberately.

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

> A user who picks **DeckBorne** with an empty `payloads/mods/` gets `30 FPS++` with no fix
> and **WILL** see vertex explosions.

Nothing blocks that combination today. Stage 40 warns when it finds no mods, and the UI row
says "Community mods (none installed)" — right before the game renders wrong. **This is the
most user-facing unfinished thing in the repo.** Options weighed, none chosen yet: hard-warn
in stage 40 when profile is deckborne and no mods are present; explain the requirement on
the DeckBorne button in the UI; or gate `30 FPS++` on the mod actually having been applied.

### Mods: PROVEN and IN USE — no longer "parked"

The old "mods are parked pending a Nexus account" note is **obsolete**. The user supplies
mods manually and the pipeline applies them. Three are in the repo's `payloads/mods/`:
`vertex-explosion-fix`, `MOAL-…`, `SFXR 60fps Cutscene Fix…`.

⚠ **The repo and the USB stick deliberately DIFFER.** The stick holds only
`vertex-explosion-fix`, so the mod ladder stays single-variable. **Exclude
`payloads/mods/` when syncing** unless told otherwise — a plain `payloads/` rsync pushes
the other two back and silently breaks the test.

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

`ui/backend.py` has three reworded messages (both tile stages + uninstall) and a
**dynamic community-mods row** that reports what is actually in `payloads/mods/`, stripping
Nexus `-<modid>-<ver>-<timestamp>` suffixes for display. **None of it is visible yet:**
`ui/run.sh` prefers `payloads/ui/DeckBorne-$(uname -m).AppImage`, which bundles its own copy
of `backend.py`. The AppImage is arch-specific and the dev box is aarch64, so **the rebuild
must happen on the Deck**: `./ui/build-appimage.sh`. Pipeline changes need no rebuild.

⚠ When editing that stage list: rows are index-aligned with install.sh's
`@@DBUI STAGE <idx>` markers. Changing row TEXT is free; adding or removing a row shifts
every later stage. That is why the no-mods case still returns a row.

### Still stale, deliberately not fixed

- **UI row 4 for DeckBorne reads "Apply config & patches (60 FPS)"** — it is 30 FPS++, not
  60. Flagged, left alone pending a call on wording.
- ~~README's Vanilla section~~ **FIXED 2026-07-19** — the patch table, the "nothing changes
  how the game plays" claim and deckborne's "everything vanilla, plus a frame-pacing patch"
  line were all rewritten to match the trimmed 8-patch vanilla.

### Profile history (restore strings live in `deckborne.env`)

1. **vanilla ← chocolate's 10-patch set; deckborne ← the same + `30 FPS++`** (current).
2. **Dropped `30 FPS++`** — the diagnostic that proved causation.
3. **Pivoted 60 → 30 FPS.** At 60 the Deck sat ~45 FPS with heavy judder. Ran on-device with
   all 11 patches confirmed applied by `memory_patcher`, write counts matching the XML
   exactly — so `deckborne.env` → stage 35 → XML → emulator memory is a **PROVEN** chain.
4. **60 FPS original.** Exact patch string preserved in the RECOVERY comment.

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
