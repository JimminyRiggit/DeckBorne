#!/usr/bin/env bash
# 99 — Uninstall DeckBorne: reverse everything the installer created, so you can
# test the whole flow from a clean slate. Invoke via:  bash uninstall.sh [opts]
#
# Options:
#   (default)     remove emulator, extracted game, mods, config.toml, Steam tile.
#                 KEEPS shadPS4 save data / shader cache and the USB logs.
#   --all         also wipe ~/.config/shadps4 and ~/.local/share/shadps4
#                 (SAVE DATA included). Prompts unless -y.
#   --purge-logs  also delete logs/ on the USB.
#   -y, --yes     don't prompt (for --all).
#   --dry-run     show what would be removed; change nothing.
#
# Deliberately NOT `set -e`: keep removing even if one step fails.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"; load_env

ALL=0; PURGE_LOGS=0; ASSUME_YES=0; DRY=0
# steam_stop sets this; initialise it so the end-of-run restart guard is safe under
# `set -u` on the dry-run path, which never calls steam_stop.
STEAM_WAS_RUNNING=0
for a in "$@"; do case "$a" in
  --all|--nuke)   ALL=1 ;;
  --purge-logs)   PURGE_LOGS=1 ;;
  -y|--yes)       ASSUME_YES=1 ;;
  --dry-run)      DRY=1 ;;
  *) warn "unknown option: $a" ;;
esac; done

# NB: use an explicit test, NOT ${DRY:+…} — that expands for any non-empty value,
# so DRY=0 printed "nothing will be deleted" while the run deleted everything.
dry_note=""
[ "$DRY" = 1 ] && dry_note=" (dry run — nothing will be deleted)"

step "Uninstalling DeckBorne$dry_note"

if [ "$ALL" = 1 ] && [ "$ASSUME_YES" != 1 ] && [ "$DRY" != 1 ]; then
  printf '  --all also deletes shadPS4 CONFIG and SAVE DATA. Type "yes" to proceed: '
  read -r ans || ans=""
  [ "$ans" = "yes" ] || die "aborted"
fi

# rm_path <path> <label>
rm_path() {
  local p="$1" l="$2" disp="${1/#$HOME/~}"
  if [ ! -e "$p" ]; then echo "  (absent)  $l — $disp"; return 0; fi
  if [ "$DRY" = 1 ]; then echo "  would remove  $l — $disp"; return 0; fi
  rm -rf "$p" && ok "removed $l — $disp" || warn "failed to remove $l — $disp"
}

# 1) Steam tiles (Steam-aware: close, edit, restart) -------------------------
# --by-exe removes EVERY tile pointing at our shadPS4 AppImage, not just the one
# named $STEAM_TILE_NAME — an uninstall should leave nothing behind, including
# tiles registered under a throwaway name (STEAM_TILE_NAME=BBTEST …), which
# name-matching stranded in the library forever.
#
# It also purges Steam's own record of each game from localconfig.vdf. Steam
# keys a non-Steam game under BOTH the signed and unsigned appid; leaving those
# behind stranded a pair of entries on every uninstall. Steam MUST be stopped for
# that edit to stick (it rewrites the file from memory on exit) — steam_stop
# below guarantees it. Pass --keep-play-records to leave playtime history alone.
step "Removing Steam tiles"
if [ "$DRY" = 1 ]; then
  # Read-only: reports the real tile/artwork/play-record counts.
  python3 "$DECKBORNE_ROOT/steam/add_shortcut.py" --remove --dry-run --by-exe \
    --exe "$APP_DIR/$SHADPS4_APPIMAGE_NAME" --name "$STEAM_TILE_NAME" \
    || warn "dry-run reported an issue"
else
  steam_stop
  python3 "$DECKBORNE_ROOT/steam/add_shortcut.py" --remove --by-exe \
    --exe "$APP_DIR/$SHADPS4_APPIMAGE_NAME" --name "$STEAM_TILE_NAME" \
    || warn "shortcut removal reported an issue (may simply not exist)"
  # Steam stays STOPPED for the rest of the uninstall — the localconfig/shortcuts edit
  # above needs it off, and removing files doesn't need it on. It's restarted once, at
  # the very end, so it comes back to a fully clean slate. (The old restart here fired
  # mid-uninstall, before the emulator and game were even removed.)
fi

# 2) Installed files ---------------------------------------------------------
step "Removing installed files"
rm_path "$APP_DIR"          "emulator + tools + boot marker"
if storage_is_external && [ ! -d "$DECKBORNE_STORAGE_ROOT" ]; then
  warn "install location is not mounted: $DECKBORNE_STORAGE_ROOT"
  warn "  The extracted game could NOT be removed. Reconnect that device and re-run"
  warn "  the uninstall to reclaim the ~30GB."
else
  rm_path "$GAMES_DIR"      "extracted game (base + update)"
fi
rm_path "$MODS_STAGE_DIR"   "mods staging"

# 3) Config / data -----------------------------------------------------------
step "Removing config"
# ⚠ SAVE DATA LIVES IN $SHADPS4_USER_DIR (~/.local/share/shadPS4), NOT in $CONFIG_DIR.
# $CONFIG_DIR (~/.config/shadps4) is a DEAD path — nothing has ever read it (see
# config/deckborne.env). The old label here claimed CONFIG_DIR held save data, which was
# wrong and dangerous to reason about: it made the harmless directory look precious and
# the precious one look absent.
if [ "$ALL" = 1 ]; then
  rm_path "$SHADPS4_USER_DIR"              "shadPS4 data dir — CONFIG, PATCHES *AND SAVE DATA*"
  rm_path "$HOME/.local/share/shadps4"     "shadPS4 data dir (lowercase variant)"
  rm_path "$CONFIG_DIR"                    "legacy ~/.config/shadps4 (dead path)"
else
  # Remove only OUR settings file, never the directory — saves and shader cache live
  # alongside it and a default uninstall must not touch them.
  rm_path "$SHADPS4_CONFIG_JSON"           "shadPS4 config.json (saves/shaders kept)"
  rm_path "$CONFIG_DIR/config.toml"        "legacy config.toml (dead path)"
  echo "  keeping shadPS4 save data + shader cache (use --all to wipe)"
fi

# Both tests matter — see CLAUDE.md (an unmounted device also has no $GAMES_DIR).
if [ "$DRY" != 1 ] && [ -d "$DECKBORNE_STORAGE_ROOT" ] && [ ! -d "$GAMES_DIR" ]; then
  forget_storage_root
  echo "  forgot the remembered install location (next install picks fresh)"
fi

# 4) USB logs ----------------------------------------------------------------
if [ "$PURGE_LOGS" = 1 ]; then
  step "Removing USB logs"
  # keep the current run's log; clear the rest of the history + snapshots
  rm_path "$DECKBORNE_ROOT/logs/state-"* "log snapshots" 2>/dev/null || true
  find "$DECKBORNE_ROOT/logs" -maxdepth 1 -type f -name 'deckborne-*.log' ! -newermt '-1 minute' -delete 2>/dev/null || true
  ok "old logs cleared (kept this run + latest.log)"
else
  echo "  keeping USB logs (use --purge-logs to clear history)"
fi

# 5) Restart Steam ----------------------------------------------------------
# Last, once every trace is gone, so Steam comes back to a clean library with nothing
# dangling. Only when it was running to begin with (steam_stop records that) and never
# on a dry run. Restarted VISIBLE (steam_start "") into its own app-steam-<pid>.scope:
# `-silent` starts Steam to a KDE tray icon that never surfaces on this Deck, so it
# read as "Steam never came back". The scope still keeps the desktop portal quiet.
if [ "$DRY" != 1 ] && [ "${STEAM_WAS_RUNNING:-0}" = 1 ]; then
  step "Restarting Steam"
  steam_restart_visible   # visible + waits for Steam to root; shared with the installer
fi

step "Uninstall complete${dry_note:+ (dry run)}"
[ "$DRY" = 1 ] || ok "Clean slate — you can re-run: bash install.sh"
