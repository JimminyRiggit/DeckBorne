#!/usr/bin/env bash
# 50 — Register the launcher tile in Steam so Bloodborne appears in Game Mode /
# Big Picture, booting straight through shadPS4 into the game. Steam is closed
# gracefully first (it rewrites shortcuts.vdf on exit) and restarted after —
# handled by the shared steam_stop/steam_start helpers. No manual steps.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"; load_env

step "Adding Steam launcher tile"

appimage="$APP_DIR/$SHADPS4_APPIMAGE_NAME"
[ -x "$appimage" ] || die "shadPS4 not installed — run 10_install_emulator.sh first"

boot_target_file="$APP_DIR/.boot_target"
[ -f "$boot_target_file" ] || die "game not installed — run 20_install_game.sh first"
boot_target="$(cat "$boot_target_file")"

# The tile is profile-INDEPENDENT: Exe is the shadPS4 AppImage and LaunchOptions point at
# the same boot target whatever profile is installed. So on a profile switch there is
# nothing here to change, and doing it anyway costs two Steam restarts and a warm-up
# launch — the one step that has ever locked the user out of their desktop.
if [ "${DECKBORNE_FORCE_TILE:-0}" != 1 ] && \
   python3 "$DECKBORNE_ROOT/steam/add_shortcut.py" --exists \
     --exe "$APP_DIR/$SHADPS4_APPIMAGE_NAME" --name "$STEAM_TILE_NAME" 2>/dev/null; then
  ok "Steam tile and artwork already installed — skipping tile, artwork and warm-up"
  log "  Steam is not stopped or restarted, and no warm-up launch happens."
  log "  To rebuild the tile anyway: DECKBORNE_FORCE_TILE=1 ./install.sh 50"
  exit 0
fi

# Confirmed shadPS4 0.16 CLI (read from the binary): -g/--game <path>, -f/--fullscreen <bool>.
launch_options="-g \"$boot_target\" -f true"
# The real, visible options the user plays with — never mutated. The probe wrapper and
# the headless warm-up both rewrite what gets *written*, but the tile must always be
# restored to THIS for normal play.
plain_launch_options="$launch_options"

# --- Probe: does Steam expand %command% for a NON-Steam shortcut? ------------
# This is the fact any "hide the warm-up" design hangs on. Steam runs a shortcut
# as `Exe LaunchOptions`, and Exe cannot change — grid_appid() hashes it, so a
# different Exe means a different appid, which breaks the artwork AND files the
# Recent entry against the wrong id. The only way to wrap the launch (in
# gamescope, say) while holding Exe still is %command% substitution.
#
# Can't be settled by looking — it needs a real launch. So: prefix the launch
# options with a wrapper that records its argv and then execs the real command.
#   - wrapper ran, argv holds the AppImage  -> %command% expanded. Wrap is viable.
#   - wrapper never ran (no log)            -> Steam passed it as an ARGUMENT to
#                                              the AppImage. Wrap is dead; the
#                                              window-manager route is all we have.
#
# Pollutes this tile's LaunchOptions permanently, so use a throwaway name:
#   DECKBORNE_PROBE_CMD=1 STEAM_TILE_NAME=BBPROBE1 ./install.sh 50
# then clean up with ./uninstall.sh (matches --by-exe, so the name doesn't matter).
PROBE_CMD_LOG="$APP_DIR/.probe-cmdline.log"
if [ "$DECKBORNE_PROBE_CMD" = 1 ]; then
  probe_wrapper="$APP_DIR/.probe-cmdline.sh"
  rm -f "$PROBE_CMD_LOG" 2>/dev/null || true
  # Log path is baked in, not passed: this runs as Steam's child and inherits
  # Steam's environment, not ours.
  cat > "$probe_wrapper" <<EOF
#!/usr/bin/env bash
# DeckBorne probe — records how Steam expanded the launch options, then hands
# off to the real command so the warm-up still behaves exactly as it would have.
{ printf 'argv[%s]:' "\$#"; printf ' <%s>' "\$@"; printf '\n'; } >> "$PROBE_CMD_LOG" 2>/dev/null
exec "\$@"
EOF
  chmod +x "$probe_wrapper" 2>/dev/null || true
  launch_options="\"$probe_wrapper\" %command% -g \"$boot_target\" -f true"
  warn "PROBE MODE (DECKBORNE_PROBE_CMD=1): launch options wrapped to test %command%."
  warn "This tile's options are now polluted — use a throwaway STEAM_TILE_NAME."
fi

artwork_dir=""
[ -d "$DECKBORNE_ROOT/$STEAM_TILE_ARTWORK_DIR" ] && \
  [ -n "$(ls -A "$DECKBORNE_ROOT/$STEAM_TILE_ARTWORK_DIR" 2>/dev/null)" ] && \
  artwork_dir="$DECKBORNE_ROOT/$STEAM_TILE_ARTWORK_DIR"

# gamescope that can actually go headless? Non-zero when gamescope is absent (the
# aarch64 dev box) or too old for the flag, so the warm-up falls back to a visible —
# but still stop_warmup-safe — launch. Confirmed on-device: SteamOS gamescope 3.16
# exits 0 for `--backend headless -- true` and 1 for the retired `--headless`.
gamescope_headless_ok() {
  command -v gamescope >/dev/null 2>&1 || return 1
  timeout 20 gamescope --backend headless -- true >/dev/null 2>&1
}

# On-disk safety net. If we've written headless launch options and anything interrupts
# us before the restore, leave the PERSISTED tile launching normally — never strand the
# user with an invisible game on their next manual launch. Best-effort, no Steam dance;
# the real restore below does the full stop/write/start.
restore_pending=0
restore_shortcut_normal() {
  [ "${restore_pending:-0}" = 1 ] || return 0
  restore_pending=0
  python3 "$DECKBORNE_ROOT/steam/add_shortcut.py" \
    --name "$STEAM_TILE_NAME" --exe "$appimage" --start-dir "$APP_DIR" \
    --launch-options "$plain_launch_options" >/dev/null 2>&1 || true
}
trap 'restore_shortcut_normal' EXIT

steam_stop      # sets STEAM_WAS_RUNNING; guarantees Steam is off before we write

# --- Headless warm-up decision ----------------------------------------------
# The warm-up is the one place DeckBorne launches the game itself, and the place the
# "stuck fullscreen, no gamepad" bug lived. Running it under a HEADLESS gamescope means
# even a warm-up that somehow survives stop_warmup can never own the screen — the user
# keeps the desktop and its mouse. gamescope is a system binary (no wrapper script to
# depend on) and grid_appid() hashes only the quoted Exe + name, so a gamescope prefix
# in LaunchOptions disturbs neither the appid nor its artwork.
#
# TEMPORARY: the tile the user plays must launch visibly, so headless options are
# written for the warm-up and restored to plain right after. Only when Steam was running
# (else no warm-up) and never together with the %command% probe (that needs a plain
# launch).
warmup_headless=0
if [ "$STEAM_WAS_RUNNING" = 1 ] && [ "$DECKBORNE_WARMUP" = 1 ] \
   && [ "$DECKBORNE_WARMUP_HEADLESS" = 1 ] && [ "$DECKBORNE_PROBE_CMD" != 1 ] \
   && gamescope_headless_ok; then
  warmup_headless=1
fi

write_launch_options="$launch_options"
if [ "$warmup_headless" = 1 ]; then
  # Canonical Steam pattern: gamescope wraps the whole %command% chain. Steam expands
  # %command% to `steam-launch-wrapper … reaper … <Exe>`, so the game ends up under
  # gamescope, headless. The trailing plain options are the game's own -g/-f args.
  write_launch_options="gamescope --backend headless -- %command% $plain_launch_options"
  restore_pending=1
  log "Warm-up will run under headless gamescope — it can never own the screen."
fi

python3 "$DECKBORNE_ROOT/steam/add_shortcut.py" \
  --name "$STEAM_TILE_NAME" \
  --exe "$appimage" \
  --start-dir "$APP_DIR" \
  --launch-options "$write_launch_options" \
  ${artwork_dir:+--artwork-dir "$artwork_dir"}

# --- Warm-up environment probe ----------------------------------------------
# Log-only. The warm-up currently launches the game fullscreen and the user sees
# it. Hiding it means either wrapping what Steam launches (gamescope) or hiding
# the window after it maps (KWin) — and both rest on Steam/compositor behaviour
# we have not verified on-device. This records the facts so the implementation
# can be built against evidence rather than blog posts. Changes nothing; every
# line is best-effort and can never fail the install.
probe_warmup_env() {
  [ "$DECKBORNE_PROBE" = 1 ] || return 0
  step "Probe: warm-up environment (log-only — nothing here changes behaviour)"

  # Decides whether the window-manager route is even possible: xdotool/wmctrl
  # are silent no-ops on Wayland, so 'wayland' here rules that approach out.
  log "session:    type=${XDG_SESSION_TYPE:-unset} desktop=${XDG_CURRENT_DESKTOP:-unset}"

  # Can we wrap the launch in a headless compositor at all?
  if command -v gamescope >/dev/null 2>&1; then
    log "gamescope:  $(command -v gamescope) [$(gamescope --version 2>&1 | head -1)]"
    # Older gamescope takes --headless; newer wants --backend headless. Try both
    # — the exit codes tell us which (if either) this build accepts.
    timeout 20 gamescope --headless -- true >/dev/null 2>&1
    log "  --headless -- true          -> exit $?"
    timeout 20 gamescope --backend headless -- true >/dev/null 2>&1
    log "  --backend headless -- true  -> exit $?"
  else
    log "gamescope:  NOT FOUND — the headless-wrap approach is out"
  fi

  # Fallback route: hide the window once it maps. Needs one of these to exist.
  local t found=0
  for t in kdotool wmctrl xdotool; do
    command -v "$t" >/dev/null 2>&1 && { log "window tool: $t -> $(command -v "$t")"; found=1; }
  done
  [ "$found" = 1 ] || log "window tool: none of kdotool/wmctrl/xdotool present"
}

# One line per process, tagged with whether the CURRENT pattern would signal it.
# `exe` is the tell: an AppImage's inner process reports /tmp/.mount_XXXX/… , which
# is exactly the string that does NOT appear in its argv.
# Read a pid's cmdline, tolerating the process vanishing mid-read.
#
# NOT `tr … < /proc/$pid/cmdline 2>/dev/null`: the redirection is performed by the
# SHELL, so the shell reports the failure and `2>/dev/null` (which belongs to tr)
# never sees it. A transient child that died between pgrep and the read leaked
# "line 115: /proc/19799/cmdline: No such file or directory" straight into the run
# log on 2026-07-17. cat owns the open, so cat's stderr redirect actually applies.
_proc_cmdline() { cat "/proc/$1/cmdline" 2>/dev/null | tr '\0' ' ' || true; }

_probe_proc() {
  local pid="$1" indent="$2" tag="$3"
  local comm exe cmd
  comm="$(cat "/proc/$pid/comm" 2>/dev/null || echo '?')"
  exe="$(readlink "/proc/$pid/exe" 2>/dev/null || echo '?')"
  cmd="$(_proc_cmdline "$pid" | cut -c1-150 || true)"
  log "$indent pid=$pid comm=$comm $tag"
  log "$indent   exe: ${exe:-?}"
  log "$indent   cmd: ${cmd:-<gone>}"
}

# Recurse down a process's children by pid — deliberately NOT by name, since the
# whole question is which processes the name misses.
_probe_kids() {
  local pid="$1" depth="${2:-0}" kid pad
  [ "$depth" -gt 4 ] && return 0
  pad="$(printf '%*s' $((depth * 2 + 4)) '')"
  for kid in $(pgrep -P "$pid" 2>/dev/null); do
    if _proc_cmdline "$kid" | grep -qF "$SHADPS4_APPIMAGE_NAME"; then
      _probe_proc "$kid" "$pad" "[pkill -f HITS this]"
    else
      _probe_proc "$kid" "$pad" "[INVISIBLE to pkill -f]  <-- survives the kill"
    fi
    _probe_kids "$kid" $((depth + 1))
  done
}

# Runs during the dwell the warm-up already waits out — read-only, costs no extra
# time. Answers the one open question: `pkill -f "$SHADPS4_APPIMAGE_NAME"` signals
# every process with that path in its argv — Steam's wrapper and reaper included —
# but is the GAME in that set, or does it survive as an orphan? Anything tagged
# INVISIBLE below is a process the current kill cannot touch. That's the line we
# need to cast at.
probe_warmup_kill_targets() {
  [ "$DECKBORNE_PROBE" = 1 ] || return 0
  local appid="${1:-}"
  step "Probe: what would pkill -f actually hit? (log-only)"
  log "pattern: '$SHADPS4_APPIMAGE_NAME'"

  # The exact set `pkill -TERM -f` would signal today. Skip our own shell and its
  # parent: -f matches on any cmdline CONTAINING the string, so a shell that merely
  # mentions it matches. That's noise here — but it's also the hazard in miniature,
  # since the real pkill would happily signal such a process for real.
  local p n=0
  for p in $(pgrep -f "$SHADPS4_APPIMAGE_NAME" 2>/dev/null); do
    if [ "$p" = "$$" ] || [ "$p" = "${PPID:-0}" ]; then
      log "  (skipped pid=$p — that's us)"
      continue
    fi
    _probe_proc "$p" "  " "[pkill -f HITS this]"; n=$((n + 1))
  done
  log "  -> $n process(es) match the pattern (excluding ourselves)"

  # Now the same launch, walked by ancestry instead of by name. Our reaper is the
  # one carrying this appid, so a second game running won't confuse it.
  local reaper_pid
  reaper_pid="$(pgrep -f "reaper SteamLaunch AppId=$appid" 2>/dev/null | head -1 || true)"
  if [ -z "$reaper_pid" ]; then
    log "no reaper for AppId=$appid — Steam may have launched it differently"
    return 0
  fi
  log "subtree under reaper (pid $reaper_pid) — by ancestry, ignoring names:"
  _probe_kids "$reaper_pid" 0
  log "Any INVISIBLE line above is a process pkill -f leaves running."
}

# --- Stopping the warm-up ---------------------------------------------------
# Steam's reaper for OUR appid. Every process in the launch chain carries the
# AppImage path in its argv, so a name match can't tell them apart — the appid can.
_reaper_pid() { pgrep -f "reaper SteamLaunch AppId=$1" 2>/dev/null | head -1 || true; }

# Is this pid a live process, or a corpse?
#
# `kill -0` is NOT the test: it succeeds for a ZOMBIE — a process that has exited but
# whose parent hasn't reaped it yet, so its pid still occupies the table. Steam's
# reaper reaps promptly (it is named for the job), but a slow reap would otherwise have
# us report a dead game as a live one and print a scary warning over a clean run.
_pid_alive() {
  local stat
  stat="$(cat "/proc/$1/stat" 2>/dev/null)" || return 1
  [ -n "$stat" ] || return 1
  # State is the char after the last ')': field 2 (comm) can itself contain spaces
  # and parens, so counting fields from the left is not safe.
  stat="${stat##*) }"
  [ "${stat%% *}" != Z ]
}

# Every descendant of a pid, deepest first, found by ancestry rather than by name —
# the whole point is to reach processes a name match misses (an AppImage's inner
# process runs out of /tmp/.mount_XXXX/ and never mentions the .AppImage at all).
_descendants_deepest_first() {
  local pid="$1" kid
  for kid in $(pgrep -P "$pid" 2>/dev/null); do
    _descendants_deepest_first "$kid"
    printf '%s\n' "$kid"
  done
}

# Stop the warm-up game — precisely, and verify it actually died.
#
# What the old `pkill -TERM -f "$SHADPS4_APPIMAGE_NAME"` did wrong, and why it could
# strand the Deck (see CLAUDE.md "Known bug"):
#
#   1. It signalled the WHOLE launch chain, because steam-launch-wrapper and reaper
#      both carry the AppImage path in their argv. Killing reaper tells Steam the
#      session ended, so Steam tears down Steam Input — the face buttons die and the
#      desktop pointer comes back — while the game itself lives on, fullscreen, now
#      unreachable by any input the user has. Only a reboot recovers.
#   2. It probably never reached the game at all. An AppImage forks: the parent's argv
#      holds the .AppImage path, the inner process runs from /tmp/.mount_XXXX/ and does
#      not. TERM the parent and the game is orphaned rather than stopped.
#   3. It then declared "Warm-up complete" unconditionally, so good runs and bad runs
#      produced identical logs. Nothing was ever verified.
#
# Instead: kill the GAME and let reaper observe it exit, which is exactly what happens
# on a normal quit — so Steam tears its input state down in the right order, on its own
# terms. reaper is Steam's supervisor; it is not ours to kill. We only touch it as a
# last resort, once the game is already confirmed gone.
stop_warmup() {
  local appid="$1" reaper targets p i alive=""

  reaper="$(_reaper_pid "$appid")"
  if [ -z "$reaper" ]; then
    warn "no reaper for AppId=$appid — nothing to stop (game may have exited already)"
    return 0
  fi

  # Snapshot the targets BEFORE signalling: once things start dying the tree changes
  # under us, and we need a fixed list to verify against afterwards.
  targets="$(_descendants_deepest_first "$reaper")"
  if [ -z "$targets" ]; then
    warn "reaper $reaper has no children — Steam launched something that never started"
    return 0
  fi

  log "Warm-up: stopping the game (reaper=$reaper, targets: $(echo "$targets" | tr '\n' ' '))…"
  for p in $targets; do kill -TERM "$p" 2>/dev/null || true; done

  for i in $(seq 1 "$DECKBORNE_WARMUP_GRACE"); do
    alive=""
    for p in $targets; do _pid_alive "$p" && alive="$alive $p"; done
    [ -z "$alive" ] && break
    sleep 1
  done

  # Escalate only against what's still standing, and only ever the game's own tree.
  if [ -n "$alive" ]; then
    warn "still alive after TERM:$alive — escalating to KILL"
    for p in $alive; do kill -KILL "$p" 2>/dev/null || true; done
    sleep 2
  fi

  # Verify. The old code claimed success here no matter what.
  alive=""
  for p in $targets; do _pid_alive "$p" && alive="$alive $p"; done
  if [ -n "$alive" ]; then
    warn "WARM-UP LEFT PROCESSES RUNNING:$alive"
    warn "If the game is on screen and unresponsive, that's the known warm-up bug."
    warn "Re-run with DECKBORNE_WARMUP=0 to skip the warm-up entirely."
    return 1
  fi

  # The game is gone. reaper should follow on its own — that's Steam noticing the
  # session ended, which is the whole reason we killed the game and not reaper.
  for i in $(seq 1 10); do _pid_alive "$reaper" || break; sleep 1; done
  if _pid_alive "$reaper"; then
    warn "reaper $reaper outlived the game — Steam may still think the tile is running"
    kill -TERM "$reaper" 2>/dev/null || true   # safe now: nothing left for it to supervise
  fi

  ok "Warm-up complete — game confirmed stopped; '$STEAM_TILE_NAME' should show in Recent"
  return 0
}

# gamescope --backend headless sits ABOVE reaper in the launch chain, so stop_warmup
# (which works DOWN from reaper) never touches it. It should exit on its own once the
# game does — its child chain collapses — but sweep any straggler so a headless
# compositor isn't left holding the GPU. A `--backend headless` gamescope is
# unambiguously ours: the Deck's Game Mode compositor is a DRM/session gamescope, never
# headless. Best-effort, and the earlier `-- true` probes are long gone by now.
sweep_headless_gamescope() {
  local p swept=0
  for p in $(pgrep -f 'gamescope.*--backend headless' 2>/dev/null); do
    if [ "$p" = "$$" ] || [ "$p" = "${PPID:-0}" ]; then continue; fi
    kill -TERM "$p" 2>/dev/null && swept=$((swept + 1)) || true
  done
  [ "$swept" -gt 0 ] && log "swept $swept lingering headless gamescope process(es)"
  return 0
}

# --- Recent Games warm-up ---------------------------------------------------
# Steam lists a game in Recent Games only once it has ACTUALLY launched it. The
# shortcut's LastPlayTime is NOT enough — verified on-device: tile 'BBTEST'
# (appid 2229845122) was written with LastPlayTime stamped and got a library
# tile, but never appeared in Recent, and Steam wrote no record for it at all.
# The only thing that correlates with a Recent entry is a real launch.
#
# So: boot the tile through Steam once, briefly, and stop it. Steam does its own
# bookkeeping and the tile lands in Recent without the user launching anything.
# Best-effort throughout — a failure here never fails the install, it just means
# the tile shows up in Recent after the first manual launch instead.
#
# Tunables: DECKBORNE_WARMUP=0 skips it; *_SETTLE/_DWELL adjust the waits.
# The warm-up POISONS shadPS4's shader cache, and the cache never recovers on its own.
#
# shadPS4 stores cache/<SERIAL>/profile.bin describing ~45 live Vulkan device properties,
# and on every launch memcmps it against the current device. On mismatch it logs
#   "Pipeline cache isn't compatible with current system. Ignoring the cache"
# and RETURNS WITHOUT REWRITING THE PROFILE (vk_pipeline_serialization.cpp:316-320) — so
# a bad profile.bin is permanent and every future launch throws the whole cache away.
#
# Our warm-up runs the game under `gamescope --backend headless`, a different device
# configuration than a real Game Mode launch. It therefore writes a profile that no real
# launch can ever match. Measured on-device: with the cache "enabled" and working, a
# second launch still compiled 187 pipelines / 289 shaders — because it was discarding
# the cache every time, and the log said so on line 111.
#
# So: throw away whatever the warm-up cached. The next real launch writes a correct
# profile and the cache starts working from the launch after that. Deleting costs
# nothing — these entries were unusable by definition.
discard_warmup_shader_cache() {
  local serial cache_dir
  serial="$(basename "$(dirname "$(cat "$APP_DIR/.boot_target" 2>/dev/null)")" 2>/dev/null)"
  [ -n "$serial" ] || return 0
  for cache_dir in "$SHADPS4_USER_DIR/cache/$serial" "$SHADPS4_USER_DIR/cache/$serial.zip"; do
    [ -e "$cache_dir" ] || continue
    rm -rf "$cache_dir" 2>/dev/null \
      && ok "Discarded warm-up shader cache ($(basename "$cache_dir")) — it was written"  \
      && ok "  under headless gamescope and would be rejected by every real launch."
  done
  return 0
}

warmup_recent() {
  if [ "$DECKBORNE_WARMUP" != 1 ]; then
    log "Recent Games warm-up disabled (DECKBORNE_WARMUP=0)"; return 0
  fi
  command -v steam >/dev/null 2>&1 || { warn "steam not on PATH — skipping warm-up"; return 0; }

  # Steam's launch URL uses the 64-bit gameid: (appid << 32) | 0x02000000. That
  # exceeds signed 64-bit, which bash's $(( )) silently wraps to a negative
  # number — so both ids are computed in Python, from the same grid_appid() the
  # shortcut itself was written with.
  local appid gameid
  read -r appid gameid < <(APPIMAGE="$appimage" TILE="$STEAM_TILE_NAME" python3 -c '
import os, sys
sys.path.insert(0, os.path.join(os.environ["DECKBORNE_ROOT"], "steam"))
from add_shortcut import grid_appid
u = grid_appid(os.environ["APPIMAGE"], os.environ["TILE"])
print(u, (u << 32) | 0x02000000)' 2>/dev/null) || true
  [ -n "${appid:-}" ] || { warn "could not compute appid — skipping warm-up"; return 0; }

  log "Waiting for Steam to come up…"
  local i
  for i in $(seq 1 60); do pgrep -x steam >/dev/null 2>&1 && break; sleep 1; done
  if ! pgrep -x steam >/dev/null 2>&1; then
    warn "Steam didn't start within 60s — skipping warm-up"; return 0
  fi
  sleep "$DECKBORNE_WARMUP_SETTLE"   # process up != shortcuts loaded

  log "Warm-up: launching the tile once so Steam records it (appid $appid)…"
  steam "steam://rungameid/$gameid" >/dev/null 2>&1 || true

  # Wait for Steam's reaper for THIS appid — not for a name match. `pgrep -f` on the
  # AppImage path matches steam-launch-wrapper and reaper too (their argv carries it),
  # so the old check here proved only that *reaper* existed, never that the game ran.
  local started=0
  for i in $(seq 1 60); do
    if [ -n "$(_reaper_pid "$appid")" ]; then started=1; break; fi
    sleep 1
  done
  if [ "$started" != 1 ]; then
    warn "warm-up launch didn't start the emulator — the tile will appear in Recent"
    warn "after you launch it once yourself. (Not fatal; everything else is installed.)"
    return 0
  fi

  # Probe while the game is up — the dwell is already happening, so this is free.
  probe_warmup_kill_targets "$appid" || true

  sleep "$DECKBORNE_WARMUP_DWELL"          # let Steam register the session
  stop_warmup "$appid" || true
  [ "${warmup_headless:-0}" = 1 ] && sweep_headless_gamescope || true
  discard_warmup_shader_cache || true

  # The verdict, straight into the run log — no reading files on the Deck.
  if [ "$DECKBORNE_PROBE_CMD" = 1 ]; then
    step "Probe: %command% expansion verdict"
    if [ -s "$PROBE_CMD_LOG" ]; then
      ok "Steam DOES expand %command% for non-Steam shortcuts."
      log "Wrapping the warm-up (gamescope et al) is viable with Exe unchanged."
      while IFS= read -r line; do log "  $line"; done < "$PROBE_CMD_LOG"
    else
      warn "Wrapper never ran — Steam did NOT expand %command%."
      warn "It passed the wrapper to the AppImage as an argument instead."
      warn "The gamescope-wrap approach is dead; only the window-manager route is left."
    fi
  fi
}

probe_warmup_env || true   # log-only; never let a probe fail an install

if [ "$STEAM_WAS_RUNNING" = 1 ]; then
  steam_start
  ok "Steam is restarting — the '$STEAM_TILE_NAME' tile will appear in your library."
  warmup_recent || true

  # If the warm-up ran headless, the tile still carries gamescope launch options.
  # Restore the plain visible ones so the user's real launches aren't invisible. This
  # must happen whatever the warm-up's outcome — the on-disk EXIT trap is only a
  # last-resort net, not the plan.
  if [ "$warmup_headless" = 1 ]; then
    step "Restoring the tile to normal (visible) launch options for play"
    steam_stop
    if python3 "$DECKBORNE_ROOT/steam/add_shortcut.py" \
         --name "$STEAM_TILE_NAME" --exe "$appimage" --start-dir "$APP_DIR" \
         --launch-options "$plain_launch_options"; then
      restore_pending=0
      ok "Tile restored — '$STEAM_TILE_NAME' now launches Bloodborne normally."
    else
      warn "Restore write failed — the EXIT trap will fix the tile file on exit."
    fi
    # Visible + WAIT for Steam to root before the install exits. A bare steam_start here
    # exits too fast and races the scope setup, so Steam never comes up (on-device
    # 2026-07-17). Shared with the uninstall so the two can't drift apart.
    steam_restart_visible
  fi
else
  ok "Shortcut written. Start Steam / switch to Game Mode to see the '$STEAM_TILE_NAME' tile."
  log "(Steam wasn't running, so the Recent Games warm-up was skipped.)"
fi
