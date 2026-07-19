#!/usr/bin/env bash
# DeckBorne — one-shot Bloodborne-on-Steam-Deck installer.
#
# Plug the USB stick into the Deck (Desktop Mode), open this folder, and run:
#     bash install.sh                # full install (all stages)
#     bash install.sh 20             # run a single stage (00/10/20/30/40/50)
#     bash install.sh collect        # snapshot shadPS4 logs + config for troubleshooting
#     bash install.sh uninstall      # remove everything (see uninstall.sh for options)
#
# Every run is logged, permanently, to  logs/  ON THE USB STICK — one timestamped
# file per run (never overwritten) plus logs/latest.log pointing at the newest.
# Hand any of those files back for debugging, or review them yourself later.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/scripts/lib.sh"; load_env

STAGES=(
  "00_preflight.sh"
  "10_install_emulator.sh"
  "20_install_game.sh"
  "30_apply_config.sh"
  "35_apply_patches.sh"
  "40_apply_mods.sh"
  "50_steam_shortcut.sh"
)

# Stages that RUN but are not shown as a row in the UI. Setup-ish work with nothing for
# the user to watch (stage 35 writes a small XML) reads as noise in a progress list next
# to "Extract Bloodborne (~30 GB)". They still log normally in the terminal.
#
# Hidden stages are also skipped when NUMBERING the UI markers, so visible indices stay
# 1..N over the visible stages only. That is what keeps STAGES_VANILLA/STAGES_DECKBORNE
# in ui/backend.py aligned without having to list hidden stages there.
UI_HIDDEN_STAGES=(
  "35_apply_patches.sh"
)

ui_hidden() {
  local s
  for s in "${UI_HIDDEN_STAGES[@]}"; do [ "$s" = "$1" ] && return 0; done
  return 1
}

run_stage() { bash "$DECKBORNE_ROOT/scripts/$1"; }

# ui_event (stage markers for the UI) now lives in lib.sh so stage scripts can emit
# sub-progress too. Format used here: STAGE <1-based-idx> <start|done|fail>.

# The full-install stage list for the active profile. DECKBORNE_PROFILE selects it:
#   vanilla   — as close to stock as possible; skips the mods stage
#   deckborne — QOL + visual mods (default)
# KEEP IN SYNC with STAGES_VANILLA / STAGES_DECKBORNE in ui/backend.py (same order).
# ⚠ MUST be called from the PARENT shell, and profile_stages must NOT die on its own.
# profile_stages is consumed as `mapfile -t run_list < <(profile_stages)` — a process
# substitution, i.e. a SUBSHELL. A `die` in there exits only the subshell: mapfile reads
# zero lines, run_list comes back EMPTY, the stage loop body never executes, and install.sh
# exits 0 having run NOTHING. Demonstrated 2026-07-18 while adding the chocolate profile —
# the typo'd profile printed its error and still reported a successful install.
# This is the same family as the warm-up bug: a failure that a cheerful exit code hides.
require_known_profile() {
  case "${DECKBORNE_PROFILE:-deckborne}" in
    vanilla|deckborne|chocolate) ;;
    *) die "unknown DECKBORNE_PROFILE '${DECKBORNE_PROFILE:-}' — expected vanilla|deckborne|chocolate" ;;
  esac
}

profile_stages() {
  case "${DECKBORNE_PROFILE:-deckborne}" in
    vanilla)
      printf '%s\n' 00_preflight.sh 10_install_emulator.sh 20_install_game.sh \
                    30_apply_config.sh 35_apply_patches.sh 50_steam_shortcut.sh ;;
    # chocolate — experimental 60 FPS test profile. Same stage list as deckborne so it
    # exercises the real shipping path; it differs only in the patch set and the emulator
    # settings those two stages pick up. CLI-only for now: ui/backend.py does not offer it.
    deckborne|chocolate)
      printf '%s\n' "${STAGES[@]}" ;;
    # Unreachable: require_known_profile has already vetted this in the PARENT shell.
    # Deliberately NOT a `die` — see the warning on that function.
    *)
      printf '%s\n' "${STAGES[@]}" ;;
  esac
}

banner() {
cat <<'BANNER'
  ____            _    ____
 |  _ \  ___  ___| | _| __ )  ___  _ __ _ __   ___
 | | | |/ _ \/ __| |/ /  _ \ / _ \| '__| '_ \ / _ \
 | |_| |  __/ (__|   <| |_) | (_) | |  | | | |  __/
 |____/ \___|\___|_|\_\____/ \___/|_|  |_| |_|\___|
        Bloodborne on Steam Deck via shadPS4
BANNER
}

# Everything below runs inside the tee pipeline, so all of it is captured.
main() {
  deckborne_sysreport
  banner

  # special sub-commands
  case "${1:-}" in
    collect|logs)    run_stage "90_collect_logs.sh"; return $? ;;
    uninstall|reset) shift; bash "$DECKBORNE_ROOT/scripts/99_uninstall.sh" "$@"; return $? ;;
  esac

  # Vet the profile BEFORE either path — a single-stage run (30/35) is exactly how
  # chocolate gets tested, so a typo there must fail here, not silently apply the
  # default profile's settings. Must be in the parent shell; see the function's warning.
  require_known_profile

  if [ $# -gt 0 ]; then
    # Run a single stage by numeric prefix.
    for s in "${STAGES[@]}"; do
      [[ "$s" == "$1"* ]] && { run_stage "$s"; return $?; }
    done
    die "no stage matching '$1' (valid: 00 10 20 30 35 40 50, or 'collect')"
  fi

  local -a run_list; mapfile -t run_list < <(profile_stages)
  [ "${#run_list[@]}" -gt 0 ] || die "internal: empty stage list for profile '${DECKBORNE_PROFILE:-deckborne}'"
  local i=0
  for s in "${run_list[@]}"; do
    # Hidden stages run and log normally, but emit no marker and do not advance the
    # UI index — so the UI's row numbering matches its own (visible-only) stage list.
    if ui_hidden "$s"; then
      run_stage "$s" || die "stage ${s%%_*} failed — see the log path printed below"
      continue
    fi
    i=$((i + 1))
    ui_event "STAGE $i start"
    if run_stage "$s"; then
      ui_event "STAGE $i done"
    else
      ui_event "STAGE $i fail"
      die "stage ${s%%_*} failed — see the log path printed below"
    fi
  done
  step "All stages complete"
  ok "Bloodborne is installed. Switch to Game Mode to launch the tile."
}

# --- permanent logging to the USB -------------------------------------------
LOG_DIR="$DECKBORNE_ROOT/logs"
mkdir -p "$LOG_DIR" 2>/dev/null || true
mode="run"
case "${1:-}" in
  collect|logs)    mode="collect" ;;
  uninstall|reset) mode="uninstall" ;;
esac
ts="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo latest)"
LOG_FILE="$LOG_DIR/deckborne-$mode-$ts.log"

# Run main, mirroring output to the terminal (with color) and to a
# color-stripped log file on the USB (clean for pasting / later review).
#
# tee writes a raw copy first and the colors are stripped afterwards, rather than
# the obvious `tee >(sed … >> "$LOG_FILE")`. A process substitution is NOT waited
# on by the shell: it created the log file immediately but the script could exit —
# or be interrupted — before sed flushed, leaving a 0-byte log and losing the
# output of exactly the runs worth reading. tee in the pipeline proper is waited on.
RAW_LOG="$LOG_FILE.raw"

# Finalise on any exit path, so an interrupted run (Ctrl+C mid-extraction) still
# leaves a readable log instead of an empty file.
finalize_log() {
  if [ -f "$RAW_LOG" ]; then
    sed 's/\x1b\[[0-9;]*m//g' "$RAW_LOG" > "$LOG_FILE" 2>/dev/null \
      || cp -f "$RAW_LOG" "$LOG_FILE" 2>/dev/null || true
    rm -f "$RAW_LOG" 2>/dev/null || true
  fi
  # An empty log is noise — only keep one with something in it.
  if [ -s "$LOG_FILE" ]; then
    # A copy, not a symlink: the USB is exFAT, which has no symlinks.
    cp -f "$LOG_FILE" "$LOG_DIR/latest.log" 2>/dev/null || true
  else
    rm -f "$LOG_FILE" 2>/dev/null || true
  fi

  # Force the bytes onto the stick. Writing the file is NOT enough: the log lives
  # on removable exFAT, and the runs worth reading are exactly the ones that end in
  # a yanked stick or a held power button. On 2026-07-17 two probe runs finalised
  # cleanly — latest.log was written 0.01s after the run log, so the content was
  # there — and both were 0 bytes by the time the stick reached the dev box. The
  # directory entries had flushed; the data hadn't. Without this the log survives
  # only the runs that didn't need logging.
  sync "$LOG_FILE" "$LOG_DIR/latest.log" 2>/dev/null || sync 2>/dev/null || true
}
trap finalize_log EXIT INT TERM

main "$@" 2>&1 | tee "$RAW_LOG"
status=${PIPESTATUS[0]}
finalize_log
trap - EXIT INT TERM

if [ -f "$LOG_FILE" ]; then
  printf '\n[DeckBorne] log saved on the USB (kept permanently):\n  %s\n  %s\n' \
    "$LOG_FILE" "$LOG_DIR/latest.log"
fi
exit "$status"
