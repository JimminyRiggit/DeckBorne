#!/usr/bin/env bash
# DeckBorne — one-shot Bloodborne-on-Steam-Deck installer.
#
# Plug the USB stick into the Deck (Desktop Mode), open this folder, and run:
#     bash install.sh                # full install (all stages)
#     bash install.sh 20             # run a single stage (00/10/20/30/40/50)
#     bash install.sh collect        # snapshot shadPS4 logs + config for troubleshooting
#     bash install.sh saves          # two-way copy of save data <-> DeckBorne/savefiles
#     bash install.sh uninstall      # remove everything (see uninstall.sh for options)
#
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

run_stage() { local s="$1"; shift; bash "$DECKBORNE_ROOT/scripts/$s" "$@"; }

require_known_profile() {
  case "${DECKBORNE_PROFILE:-deckborne}" in
    vanilla|deckborne|chocolate) ;;
    *) die "unknown DECKBORNE_PROFILE '${DECKBORNE_PROFILE:-}' — expected vanilla|deckborne|chocolate" ;;
  esac
}

require_known_target() {
  case "${DECKBORNE_TARGET:-deck30}" in
    deck30|deck60|desktop) ;;
    *) die "unknown DECKBORNE_TARGET '${DECKBORNE_TARGET:-}' — expected deck30|deck60|desktop" ;;
  esac
  if [ "${DECKBORNE_PROFILE:-deckborne}" != deckborne ] && [ "${DECKBORNE_TARGET:-deck30}" != deck30 ]; then
    warn "DECKBORNE_TARGET='${DECKBORNE_TARGET}' is set, but profile"
    warn "  '${DECKBORNE_PROFILE:-deckborne}' ignores it — only deckborne reads a target."
  fi
}

profile_stages() {
  case "${DECKBORNE_PROFILE:-deckborne}" in
    vanilla)
      printf '%s\n' 00_preflight.sh 10_install_emulator.sh 20_install_game.sh \
                    30_apply_config.sh 35_apply_patches.sh 40_apply_mods.sh \
                    50_steam_shortcut.sh ;;
    # chocolate — experimental test profile. Same stage list as deckborne so it

    deckborne|chocolate)
      printf '%s\n' "${STAGES[@]}" ;;
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

  keep_awake_begin
  trap keep_awake_end EXIT

  # special sub-commands
  case "${1:-}" in
    collect|logs)    run_stage "90_collect_logs.sh"; return $? ;;
    saves-export|export-save)  run_stage "sync_saves.sh" --export; return $? ;;
    saves-import|import-save)  run_stage "sync_saves.sh" --import; return $? ;;
    saves|savesync)  die "say which direction you mean:
     ./install.sh saves-export   copy the Deck's save out to DeckBorne/savefiles/
     ./install.sh saves-import   copy DeckBorne/savefiles/ onto the Deck" ;;
    uninstall|reset) shift; bash "$DECKBORNE_ROOT/scripts/99_uninstall.sh" "$@"; return $? ;;
  esac

  # Vet the profile BEFORE either path — a single-stage run (30/35) is exactly how
  # chocolate gets tested, so a typo there must fail here, not silently apply
  require_known_profile
  require_known_target

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
  saves-export|export-save)  mode="saves-export" ;;
  saves-import|import-save)  mode="saves-import" ;;
  saves|savesync)  mode="saves" ;;
  uninstall|reset) mode="uninstall" ;;
esac
ts="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo latest)"
LOG_FILE="$LOG_DIR/deckborne-$mode-$ts.log"

# Run main, mirroring output to the terminal (with color) and to a
# color-stripped log file on the USB (clean for pasting / later review).

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
