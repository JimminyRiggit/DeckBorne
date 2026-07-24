#!/usr/bin/env bash
# 20 — Install the game by EXTRACTING the .pkg files into the shadPS4 games dir.
#
# Why extraction (not an emulator "install"): shadPS4 0.16 removed its built-in
# PKG installer — the SDL build can only launch an already-extracted game. We use
# the ShadPs4Plus standalone extractor (same code shadPS4 used to ship), producing
# a natively-compatible game folder with eboot.bin.
#
# Layout produced (shadPS4's convention — base + sibling -UPDATE folder that the
# emulator auto-applies when you boot the base):
#   $GAMES_DIR/CUSA03173/eboot.bin           <- base game
#   $GAMES_DIR/CUSA03173-UPDATE/eboot.bin    <- v1.09 update (auto-applied)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"; load_env

# Identify the game by PKG content (title-id in the header), not by filename, so any
# release/region naming works and we extract into the CORRECT CUSAxxxxx folder.
base_pkg="$(discover_base_pkg || true)"
[ -n "$base_pkg" ] || die "no PS4 .pkg found under game-pkg/"
title_id="$(pkg_title_id "$base_pkg")"; [ -n "$title_id" ] || title_id="$GAME_TITLE_ID"
update_pkg="$(discover_update_pkg "$base_pkg" || true)"

step "Installing $GAME_NAME ($title_id)"

# Extraction unpacks ~30GB into .extract-tmp before swapping it into place. An
# interrupted run (Ctrl+C during the several-minute base extraction) used to leave
# all of it stranded, with nothing to reclaim the space until the next stage-20 run
# happened to `rm -rf` it. Sweep it on any exit — success, failure, or signal.
# Safe on success: the game root is moved OUT of tmp before this runs.
_sweep_extract_tmp() { rm -rf "$GAMES_DIR/.extract-tmp" 2>/dev/null || true; }
MOVE_TMP=""
_sweep_move_tmp() { [ -n "$MOVE_TMP" ] && rm -rf "$MOVE_TMP" 2>/dev/null; return 0; }
# ⚠ A cleanup trap on INT/TERM MUST exit. Bash resumes the script after a signal handler
# that doesn't, so the old `trap _sweep_extract_tmp EXIT INT TERM` swept the temp dir and
# then carried on extracting into the directory it had just deleted. Harmless for the
# extract (it fails soon after), but the relocation path below goes on to DELETE THE
# SOURCE, so "continues after cleanup" is not a state it may ever reach.

# ⚠ Kill the worker BEFORE sweeping, or Ctrl+C orphans it: the copy/extract keeps running
# with no script attached, recreates the temp dir the sweep just removed, and goes on
# writing gigabytes to the user's card in the background. Observed directly — the tmp dir
# came back after cleanup. By PID, never `pkill -f` (see CLAUDE.md: that pattern also
# matches the shell issuing it).
WORKER_PIDS=""
_stop_workers() {
  local p
  for p in $WORKER_PIDS; do kill -TERM "$p" 2>/dev/null || true; done
  for p in $WORKER_PIDS; do wait "$p" 2>/dev/null || true; done
  WORKER_PIDS=""
  return 0
}
_sweep_all() { _stop_workers; _sweep_move_tmp; _sweep_extract_tmp; }
_on_signal() { _sweep_all; exit 130; }
trap _sweep_all EXIT
trap _on_signal INT TERM

mkdir -p "$GAMES_DIR"

# --- ensure the extractor is available (bundled on USB, else download) -------
extractor="$APP_DIR/tools/$PKG_EXTRACTOR_APPIMAGE"
if [ -f "$extractor" ] && [ "$(sha256sum "$extractor" | awk '{print $1}')" = "$PKG_EXTRACTOR_SHA256" ]; then
  ok "PKG extractor already present"
else
  mkdir -p "$APP_DIR/tools"
  bundled="$DECKBORNE_ROOT/payloads/shadps4/$PKG_EXTRACTOR_APPIMAGE"
  if [ -f "$bundled" ]; then
    log "Using bundled PKG extractor from USB payload"
    cp "$bundled" "$extractor"
  else
    log "Downloading PKG extractor: $PKG_EXTRACTOR_URL"
    curl -fL --progress-bar -o "$extractor" "$PKG_EXTRACTOR_URL" || die "extractor download failed"
  fi
  verify_sha256 "$extractor" "$PKG_EXTRACTOR_SHA256"
fi
chmod +x "$extractor"

# The extractor is a tiny AppImage; run it via extract-and-run to avoid any
# FUSE dependency (robust on SteamOS). Args: <pkg> <output-dir>.
run_extractor() { "$extractor" --appimage-extract-and-run "$@"; }

_gb() { awk -v b="${1:-0}" 'BEGIN{ printf "%.1fG", b/1073741824 }'; }

# Sample the growing output dir against the .pkg size and report progress, until the
# extractor (pid $4) exits. Best-effort: never fails the install. Emits a UI marker
# (@@DBUI SUBPROGRESS <0..1>, so the bar fills mid-stage instead of freezing) plus a
# human line per whole percent (visible in the terminal + run log).
_extract_progress() {
  local tmp="$1" pkg="$2" label="$3" epid="$4"
  local total cur pct frac last=-1
  total="$(stat -c%s "$pkg" 2>/dev/null || echo 0)"; [ "$total" -gt 0 ] || return 0
  while kill -0 "$epid" 2>/dev/null; do
    sleep 4
    cur="$(du -sb "$tmp" 2>/dev/null | cut -f1)"; cur="${cur:-0}"
    pct=$(( cur * 100 / total )); [ "$pct" -gt 99 ] && pct=99
    frac="$(awk -v c="$cur" -v t="$total" 'BEGIN{ f=c/t; if(f>0.99)f=0.99; printf "%.3f", f }')"
    ui_event "SUBPROGRESS $frac"
    if [ "$pct" != "$last" ]; then
      log "  extracting $label — ${pct}% ($(_gb "$cur") / $(_gb "$total"))"
      last="$pct"
    fi
  done
}

# extract_pkg <pkg> <final-dir> <label>
extract_pkg() {
  local pkg="$1" final="$2" label="$3"
  local detail="$DECKBORNE_ROOT/logs/extract-$(basename "$final").log"
  local tmp="$GAMES_DIR/.extract-tmp"
  rm -rf "$tmp"; mkdir -p "$tmp" "$DECKBORNE_ROOT/logs"

  log "Extracting $label — can take several minutes (30GB base). Per-file detail → ${detail#"$DECKBORNE_ROOT"/}"
  # Run the extractor in the background so we can watch the output dir grow and report
  # progress; the sampler self-exits when the extractor pid dies.
  run_extractor "$pkg" "$tmp" >"$detail" 2>&1 &
  local epid=$!
  _extract_progress "$tmp" "$pkg" "$label" "$epid" &
  local spid=$!
  WORKER_PIDS="$epid $spid"
  wait "$epid"; local rc=$?
  kill "$spid" 2>/dev/null; wait "$spid" 2>/dev/null || true
  WORKER_PIDS=""
  if [ "$rc" -ne 0 ]; then
    warn "extractor failed — last 15 lines:"; tail -n 15 "$detail" 2>/dev/null
    rm -rf "$tmp"; die "$label extraction failed (full output: $detail)"
  fi

  # Find eboot.bin wherever the tool placed it; that dir is the game root.
  local eb; eb="$(find "$tmp" -type f -iname 'eboot.bin' -print -quit 2>/dev/null || true)"
  if [ -z "$eb" ]; then
    warn "no eboot.bin produced — last 15 lines:"; tail -n 15 "$detail" 2>/dev/null
    rm -rf "$tmp"; die "$label: eboot.bin not found after extraction (full output: $detail)"
  fi
  local root; root="$(dirname "$eb")"

  rm -rf "$final"; mkdir -p "$(dirname "$final")"
  mv "$root" "$final"
  rm -rf "$tmp"
  ok "$label → ${final#"$HOME"/}  ($(du -sh "$final" 2>/dev/null | cut -f1))"
}

# Switching profiles re-runs the whole pipeline, and re-extracting 30GB to change a
# patch set is ~20 wasted minutes. If a complete extraction is already sitting there,
# skip straight to the profile stages. Completeness means eboot.bin for the base AND
# for the update when an update .pkg exists — a half-extracted install must not pass.
game_root="$GAMES_DIR/$title_id"
update_root="$GAMES_DIR/${title_id}-UPDATE"

# --- relocation: the install already exists, just not where it was asked for ------
# A user who installed to the internal drive and then picks the SD card should not pay a
# ~20 minute re-extract. Copying is faster, needs no .pkg on hand, and — unlike an
# extract — carries the mod state with it (<title>.pre-mods holds the ORIGINAL bytes that
# make repeated profile switching safe; losing it would strand a modded game as "stock").
# The three per-title artifacts, and the whole set: never the entire games dir, which may
# hold other titles the user installed with shadPS4 themselves.
title_artifacts() {
  printf '%s\n' "$title_id" "${title_id}-UPDATE" "${title_id}.pre-mods"
}

# "<file-count> <total-bytes>", counting REGULAR FILES ONLY. Directory inodes are
# deliberately excluded: their apparent size is filesystem-dependent (ext4 vs f2fs report
# different st_size for the same entries), so including them would make a perfectly good
# cross-device copy fail verification.
_file_stats() {
  find "$@" -type f -printf '%s\n' 2>/dev/null \
    | awk '{n++; s+=$1} END{printf "%d %d\n", n+0, s+0}'
}

_copy_progress() {
  local dst="$1" total="$2" label="$3" cpid="$4"
  local cur pct frac last=-1
  [ "$total" -gt 0 ] || return 0
  while kill -0 "$cpid" 2>/dev/null; do
    sleep 4
    cur="$(du -sb "$dst" 2>/dev/null | cut -f1)"; cur="${cur:-0}"
    pct=$(( cur * 100 / total )); [ "$pct" -gt 99 ] && pct=99
    frac="$(awk -v c="$cur" -v t="$total" 'BEGIN{ f=c/t; if(f>0.99)f=0.99; printf "%.3f", f }')"
    ui_event "SUBPROGRESS $frac"
    if [ "$pct" != "$last" ]; then
      log "  $label — ${pct}% ($(_gb "$cur") / $(_gb "$total"))"
      last="$pct"
    fi
  done
}

# relocate_install <source-games-dir>
# Copy-verify-swap, then delete the source. The source is NEVER touched until the
# destination is verified, so an interrupted move costs disk space, never the install.
relocate_install() {
  local src_games="$1" a moved=0 count total
  local -a present=()
  while IFS= read -r a; do [ -d "$src_games/$a" ] && present+=("$a"); done < <(title_artifacts)
  [ "${#present[@]}" -gt 0 ] || return 1

  local -a src_dirs=()
  for a in "${present[@]}"; do src_dirs+=("$src_games/$a"); done
  read -r count total < <(_file_stats "${src_dirs[@]}")

  step "Moving the existing install to the new location"
  log "  from : $src_games"
  log "  to   : $GAMES_DIR"
  log "  size : $(_gb "$total") in $count files  (${#present[@]} folders: ${present[*]})"
  ui_event "STATUS Ah! You are a seasoned hunter, familiar with the scourge. Good. Tonights hunt is no place for the untrained and unfamiliar. Moving the install to the requested location, see you soon."
  ui_event "SUBLABEL Moving Game Package to target install location"
  ui_event "SUBPROGRESS 0"

  # Same filesystem: rename is instant, so skip the copy machinery entirely.
  local same=0
  if [ "$(stat -c %d "$src_games" 2>/dev/null || echo x)" = \
       "$(stat -c %d "$GAMES_DIR" 2>/dev/null || echo y)" ]; then same=1; fi

  # 3% margin: `total` counts file bytes only, and the destination also pays for
  # directory inodes and per-file slack.
  local avail need
  avail="$(df -Pk "$GAMES_DIR" | awk 'NR==2{print $4}')"
  need=$(( total + total / 33 ))
  if [ "$same" = 0 ] && [ $(( avail * 1024 )) -lt "$need" ]; then
    die "not enough room to move the install: needs $(_gb "$total"), the destination has
  $(_gb $(( avail * 1024 ))) free. Free space or choose a different install location."
  fi

  MOVE_TMP="$GAMES_DIR/.move-tmp"
  rm -rf "$MOVE_TMP"; mkdir -p "$MOVE_TMP"

  if [ "$same" = 1 ]; then
    for a in "${present[@]}"; do mv "$src_games/$a" "$MOVE_TMP/$a" || die "move failed: $a"; done
    ok "Same filesystem — relocated instantly"
  else
    cp -a --no-preserve=ownership "${src_dirs[@]}" "$MOVE_TMP/" &
    local cpid=$!
    _copy_progress "$MOVE_TMP" "$total" "copying game files" "$cpid" &
    local spid=$!
    WORKER_PIDS="$cpid $spid"
    wait "$cpid"; local rc=$?
    kill "$spid" 2>/dev/null; wait "$spid" 2>/dev/null || true
    WORKER_PIDS=""
    [ "$rc" -eq 0 ] || die "copying the game to $GAMES_DIR failed (rc=$rc) — the original at
  $src_games has NOT been touched. Free space or choose a different install location."

    # Verify before anything is deleted: eboot.bin present, and file count AND total
    # bytes both matching. Checksumming 30GB would cost more than the copy did.
    [ -f "$MOVE_TMP/$title_id/eboot.bin" ] || die "copy verification failed: no eboot.bin at
  $MOVE_TMP/$title_id — the original at $src_games has NOT been touched."
    local -a dst_dirs=() dcount dtotal
    for a in "${present[@]}"; do dst_dirs+=("$MOVE_TMP/$a"); done
    read -r dcount dtotal < <(_file_stats "${dst_dirs[@]}")
    if [ "$dcount" != "$count" ] || [ "$dtotal" != "$total" ]; then
      die "copy verification failed: $dcount files / $(_gb "$dtotal") arrived, expected
  $count files / $(_gb "$total") — the original at $src_games has NOT been touched."
    fi
    ok "Copy verified — $dcount files, $(_gb "$dtotal")"
  fi

  for a in "${present[@]}"; do
    rm -rf "${GAMES_DIR:?}/$a"
    mv "$MOVE_TMP/$a" "$GAMES_DIR/$a" || die "could not place $a into $GAMES_DIR"
    moved=$((moved + 1))
  done
  rm -rf "$MOVE_TMP"; MOVE_TMP=""

  if [ "$same" = 0 ]; then
    for a in "${present[@]}"; do rm -rf "${src_games:?}/$a"; done
    rmdir "$src_games" 2>/dev/null || true
    ok "Old copy removed from $src_games"
  fi
  ui_event "SUBPROGRESS 1"
  ok "Install moved ($moved folders) — no re-extraction needed"
  return 0
}

game_already_extracted() {
  [ -f "$game_root/eboot.bin" ] || return 1
  [ -z "$update_pkg" ] || [ -f "$update_root/eboot.bin" ] || return 1
  return 0
}

# Before deciding to extract: is this install simply sitting on another device? Only
# consulted when it is NOT already here, so a copy at the destination always wins.
relocated=0
if [ "${DECKBORNE_FORCE_EXTRACT:-0}" != 1 ] && [ "${DECKBORNE_NO_RELOCATE:-0}" != 1 ] \
   && ! game_already_extracted; then
  mapfile -t other_roots < <(
    python3 "$DECKBORNE_ROOT/scripts/detect_storage.py" --find-install "$title_id" 2>/dev/null \
      | grep -vx "$DECKBORNE_STORAGE_ROOT" || true)
  if [ "${#other_roots[@]}" -gt 1 ]; then
    warn "Found this game on more than one device: ${other_roots[*]}"
    warn "  Refusing to guess which one to move — extracting fresh instead."
    warn "  Delete the copies you don't want, or set DECKBORNE_STORAGE_ROOT to the one to keep."
  elif [ "${#other_roots[@]}" -eq 1 ] && [ -n "${other_roots[0]}" ]; then
    ok "Game is already installed on another device: ${other_roots[0]}"
    # NOT `relocate_install … && relocated=1`: under `set -e` a trailing failed && is the
    # last command of this branch, so a "nothing to move" return would kill the stage.
    if relocate_install "${other_roots[0]}/Games/shadps4"; then relocated=1; fi
  fi
fi

if [ "$relocated" = 1 ]; then
  :
elif [ "${DECKBORNE_FORCE_EXTRACT:-0}" != 1 ] && game_already_extracted; then
  ok "Game already extracted — skipping the ~30GB extraction"
  log "  base   : ${game_root#"$HOME"/}  ($(du -sh "$game_root" 2>/dev/null | cut -f1))"
  if [ -n "$update_pkg" ]; then
    log "  update : ${update_root#"$HOME"/}  ($(du -sh "$update_root" 2>/dev/null | cut -f1))"
  fi
  log "  To force a clean re-extract: DECKBORNE_FORCE_EXTRACT=1 ./install.sh 20"
  ui_event "SUBPROGRESS 1"

  # An existing install may carry mods from a previous profile. Stage 40 now runs for
  # EVERY profile and reconciles them (vanilla reverts, deckborne revert-then-applies),
  # so this is informational — do not restore the old "they stay applied" warning.
  if [ -d "$game_root/../$(basename "$game_root").pre-mods" ]; then
    log "  mods from a previous install are present; the mod stage will reconcile them"
  fi
else
  [ "${DECKBORNE_FORCE_EXTRACT:-0}" = 1 ] && log "DECKBORNE_FORCE_EXTRACT=1 — re-extracting even though a copy may exist"
  extract_pkg "$base_pkg" "$game_root" "base game"
  if [ -n "$update_pkg" ]; then
    extract_pkg "$update_pkg" "$update_root" "update"
  else
    warn "no update .pkg found — running base game un-patched"
  fi
fi

# Boot target for the Steam tile (shadPS4 auto-applies the sibling -UPDATE folder).
eboot="$GAMES_DIR/$title_id/eboot.bin"
[ -f "$eboot" ] || die "expected boot file missing: $eboot"
printf '%s\n' "$eboot" > "$APP_DIR/.boot_target"
ok "Game installed — boot target: $eboot"
