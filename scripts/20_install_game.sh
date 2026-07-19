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
[ -n "$base_pkg" ] || die "no PS4 .pkg found under game-ISO/"
title_id="$(pkg_title_id "$base_pkg")"; [ -n "$title_id" ] || title_id="$GAME_TITLE_ID"
update_pkg="$(discover_update_pkg "$base_pkg" || true)"

step "Installing $GAME_NAME ($title_id)"

# Extraction unpacks ~30GB into .extract-tmp before swapping it into place. An
# interrupted run (Ctrl+C during the several-minute base extraction) used to leave
# all of it stranded, with nothing to reclaim the space until the next stage-20 run
# happened to `rm -rf` it. Sweep it on any exit — success, failure, or signal.
# Safe on success: the game root is moved OUT of tmp before this runs.
_sweep_extract_tmp() { rm -rf "$GAMES_DIR/.extract-tmp" 2>/dev/null || true; }
trap _sweep_extract_tmp EXIT INT TERM

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
  wait "$epid"; local rc=$?
  kill "$spid" 2>/dev/null; wait "$spid" 2>/dev/null || true
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

extract_pkg "$base_pkg" "$GAMES_DIR/$title_id" "base game"
if [ -n "$update_pkg" ]; then
  extract_pkg "$update_pkg" "$GAMES_DIR/${title_id}-UPDATE" "update"
else
  warn "no update .pkg found — running base game un-patched"
fi

# Boot target for the Steam tile (shadPS4 auto-applies the sibling -UPDATE folder).
eboot="$GAMES_DIR/$title_id/eboot.bin"
[ -f "$eboot" ] || die "expected boot file missing: $eboot"
printf '%s\n' "$eboot" > "$APP_DIR/.boot_target"
ok "Game installed — boot target: $eboot"
