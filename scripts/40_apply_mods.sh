#!/usr/bin/env bash
# 40 — Apply mods. Mods for Bloodborne/shadPS4 are file overlays that merge into
# the installed game folder (<GAMES_DIR>/<title-id>/).
#
# HOW TO ADD A MOD:
#   Drop its extracted files into  payloads/mods/<mod-name>/  mirroring the
#   in-game folder layout (e.g. payloads/mods/60fps/ containing the files that
#   belong at the game root). Merged in alphabetical order, so prefix with
#   00_, 10_, ... to control precedence when two mods touch the same file.
#
# REVERTING:  ./40_apply_mods.sh --revert   restores the pre-mods game state.
#
# TWO TRAPS THIS SCRIPT EXISTS TO CATCH (both cost real debugging):
#   1. A file-overlay mod OVERWRITES vanilla files. The old code recorded only a
#      LIST of filenames and called it a backup — the original bytes were gone, so
#      "reversible" meant re-extracting 30GB. We now copy each about-to-be-clobbered
#      file into <game>.pre-mods/files/ BEFORE writing over it.
#   2. Nexus archives almost always carry a wrapper folder (`CoolMod v1.2/dvdroot_ps4/…`).
#      Extract that straight into payloads/mods/ and a blind rsync merges one level too
#      deep — nothing lands, no error, stage reports success. We validate the layout
#      against the real game root, auto-descend a single wrapper when its children
#      clearly match, and LOUDLY skip anything we can't place.
#
# This stage never fails the install: a mod that can't be placed is skipped with a
# warning and counted in the summary. Reporting "applied 2, SKIPPED 1" is honest;
# dying here would strand a good install with no Steam tile.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"; load_env

boot_target_file="$APP_DIR/.boot_target"
[ -f "$boot_target_file" ] || die "game not installed yet — run 20_install_game.sh first"
game_root="$(dirname "$(cat "$boot_target_file")")"
backup_dir="$game_root/../$(basename "$game_root").pre-mods"
backup_files="$backup_dir/files"
added_list="$backup_dir/added.list"

# ---- revert -----------------------------------------------------------------
# Restores originals and deletes files the mods added. Leaves the backup in place
# so a failed revert can be retried.
if [ "${1:-}" = "--revert" ]; then
  step "Reverting mods"
  [ -d "$backup_dir" ] || die "no mod backup at $backup_dir — nothing to revert"

  restored=0
  if [ -d "$backup_files" ]; then
    while IFS= read -r rel; do
      [ -n "$rel" ] || continue
      mkdir -p "$game_root/$(dirname "$rel")"
      cp -a "$backup_files/$rel" "$game_root/$rel" && restored=$((restored + 1))
    done < <(cd "$backup_files" && find . -type f -printf '%P\n' | sort)
  fi

  removed=0
  if [ -f "$added_list" ]; then
    # reverse order so nested files go before the dirs that held them
    while IFS= read -r rel; do
      [ -n "$rel" ] || continue
      [ -e "$game_root/$rel" ] || continue
      rm -f "$game_root/$rel" && removed=$((removed + 1))
    done < <(sort -r "$added_list")
    # prune directories the mods left empty; never touch a dir with content in it
    while IFS= read -r rel; do
      d="$game_root/$(dirname "$rel")"
      [ -d "$d" ] && rmdir -p --ignore-fail-on-non-empty "$d" 2>/dev/null || true
    done < <(sort -r "$added_list")
  fi

  ok "Restored $restored original file(s), removed $removed added file(s)"
  ok "Game reverted to pre-mods state: $game_root"
  exit 0
fi

# ---- apply ------------------------------------------------------------------
step "Applying mods"
ok "Game root: $game_root"

mods_src="$DECKBORNE_ROOT/payloads/mods"
shopt -s nullglob
mod_dirs=( "$mods_src"/*/ )
shopt -u nullglob

# The catalog is a POINTER LIST — mod URLs, never mod files. DeckBorne must not
# redistribute mods (see config/mods.catalog for why). Report what's known and what's
# present; the user does the downloading Nexus requires them to do.
catalog="$DECKBORNE_ROOT/config/mods.catalog"
report_catalog() {
  [ -f "$catalog" ] || return 0
  local id name url hint missing=0
  while IFS='|' read -r id name url hint; do
    case "$id" in ''|\#*) continue ;; esac
    id="${id// /}"
    [ -d "$mods_src/$id" ] && [ -n "$(ls -A "$mods_src/$id" 2>/dev/null)" ] && continue
    [ "$missing" -eq 0 ] && { echo; log "Known compatible mods you don't have installed:"; }
    missing=1
    printf '     %-34s %s\n' "$name" "$url"
    printf '     %-34s -> extract into payloads/mods/%s/\n' "" "$id"
    [ -n "$hint" ] && printf '     %-34s    %s\n' "" "$hint"
  done < "$catalog"
  [ "$missing" -eq 1 ] && log "  (all optional — nothing here is required to play)"
  return 0
}

if [ ${#mod_dirs[@]} -eq 0 ]; then
  warn "No mods in payloads/mods/ — skipping (this is fine; the game runs without mods)."
  report_catalog
  exit 0
fi

# _entries_match <dir> — 0 if any top-level entry of <dir> also exists in the game
# root. That shared name is what says "this tree is rooted where the game is rooted".
_entries_match() {
  local d="$1" e base
  for e in "$d"/*; do
    [ -e "$e" ] || continue
    base="$(basename "$e")"
    # case-insensitive: PS4 filesystems and extractor output disagree on case
    if find "$game_root" -maxdepth 1 -iname "$base" -print -quit | grep -q .; then
      return 0
    fi
  done
  return 1
}

# _resolve_mod_root <dir> — echoes the directory to merge FROM, or nothing if the
# layout can't be placed. Handles the single-wrapper-folder case that Nexus zips
# almost always have.
_resolve_mod_root() {
  local d="$1" inner=() n
  if _entries_match "$d"; then printf '%s' "$d"; return 0; fi
  shopt -s nullglob; inner=( "$d"/*/ ); shopt -u nullglob
  n=${#inner[@]}
  # exactly one subdirectory and nothing else at top level → classic wrapper
  if [ "$n" -eq 1 ] && [ "$(find "$d" -maxdepth 1 -type f | wc -l)" -eq 0 ]; then
    if _entries_match "${inner[0]}"; then printf '%s' "${inner[0]}"; return 0; fi
  fi
  return 1
}

mkdir -p "$backup_files"
touch "$added_list"

# Full pristine listing, once — cheap reference for "what did the game look like".
manifest="$backup_dir/pristine.manifest"
[ -f "$manifest" ] || find "$game_root" -type f -printf '%P\n' 2>/dev/null | sort > "$manifest"

applied=0 skipped=0 overwritten=0 added=0
declare -a skipped_names=()
declare -a shadowed=()
declare -a locale_targets=()

# shadPS4 boots the BASE folder and auto-applies the sibling -UPDATE over it, so a file
# that exists in BOTH is served from the update — meaning a mod merged into the base is
# INVISIBLE even though every byte landed correctly. That would look exactly like a
# working install with a mod that does nothing. BB_Launcher's README recommends a
# separate update folder for precisely this reason. We can't fix it blind, but we can
# refuse to be silent about it.
update_root="${game_root}-UPDATE"

for mod in "${mod_dirs[@]}"; do
  name="$(basename "$mod")"
  log "Merging mod: $name"

  if ! src="$(_resolve_mod_root "$mod")"; then
    warn "SKIPPED '$name' — its layout doesn't match the game root."
    warn "  it contains:  $(cd "$mod" && ls -A | head -5 | tr '\n' ' ')"
    warn "  game root has: $(cd "$game_root" && ls -A | head -5 | tr '\n' ' ')"
    warn "  Fix: the mod folder's contents must sit at the SAME level as the game root"
    warn "  (extract so eboot.bin/dvdroot_ps4 line up), then re-run this stage."
    skipped=$((skipped + 1)); skipped_names+=( "$name" )
    continue
  fi
  [ "$src" = "$mod" ] || log "  descended into wrapper folder: $(basename "$src")"

  # Copy file-by-file so every overwrite is backed up first and every addition is
  # recorded. Slower than a blind rsync, but this is what makes revert real.
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    dest="$game_root/$rel"
    if [ -e "$dest" ]; then
      # back up the ORIGINAL only once — a later mod must not overwrite the
      # pristine copy with an earlier mod's version
      if [ ! -e "$backup_files/$rel" ]; then
        mkdir -p "$backup_files/$(dirname "$rel")"
        cp -a "$dest" "$backup_files/$rel"
      fi
      overwritten=$((overwritten + 1))
    else
      grep -qxF "$rel" "$added_list" || printf '%s\n' "$rel" >> "$added_list"
      added=$((added + 1))
    fi
    mkdir -p "$(dirname "$dest")"
    cp -a "$src/$rel" "$dest"
    # would the update folder's copy win over what we just wrote?
    [ -e "$update_root/$rel" ] && shadowed+=( "$rel" )
    # note any per-language menu dir this mod writes into (see the locale trap below)
    case "$rel" in
      dvdroot_ps4/menu/*/*) locale_targets+=( "$(basename "$(dirname "$rel")")" ) ;;
    esac
  done < <(cd "$src" && find . -type f -printf '%P\n' | sort)

  ok "applied $name"
  applied=$((applied + 1))
done

# Honest summary. "applied N" alone would read as success even when a mod was skipped.
if [ "$skipped" -gt 0 ]; then
  warn "Mods applied: $applied — ${skipped} SKIPPED: ${skipped_names[*]}"
  warn "The game is playable, but the skipped mod(s) are NOT installed."
else
  ok "Mods applied: $applied ($overwritten file(s) replaced, $added added)"
fi

# LOCALE TRAP. Bloodborne keeps per-language copies of menu assets — menu/engus (US),
# menu/enggb (EU/GB), and so on — and reads exactly ONE of them, decided by the release
# you own. Most mods are authored against the US release, so a EU dump (CUSA03173 GOTY)
# quietly reads menu/enggb while the mod replaces menu/engus.
#
# Cost of not warning, measured: a wingdings font mod applied perfectly, reported
# "1 file(s) replaced", and changed nothing in game. The emulator's own log gave it away
# with `open: path = /app0/dvdroot_ps4/menu/enggb/font.gfx`. Every check we had passed.
if [ ${#locale_targets[@]} -gt 0 ]; then
  for loc in $(printf '%s\n' "${locale_targets[@]}" | sort -u); do
    siblings=()
    for d in "$game_root/dvdroot_ps4/menu"/*/; do
      [ -d "$d" ] || continue
      b="$(basename "$d")"
      [ "$b" = "$loc" ] || siblings+=( "$b" )
    done
    if [ ${#siblings[@]} -gt 0 ]; then
      warn "This mod writes to menu/$loc, but the game also has: ${siblings[*]}"
      warn "  Bloodborne reads only ONE of these, chosen by your release region. If the"
      warn "  mod has no visible effect, it targeted the wrong locale — copy its files"
      warn "  into the right one. shad_log.txt shows which the game opens; look for"
      warn "  'open: path = /app0/dvdroot_ps4/menu/<locale>/'."
    fi
  done
fi

# A mod that lands perfectly and is then shadowed by the update folder is the worst
# possible outcome: every check passes and the game looks untouched. Say so loudly.
if [ ${#shadowed[@]} -gt 0 ]; then
  warn "${#shadowed[@]} modded file(s) ALSO exist in $(basename "$update_root")."
  warn "  shadPS4 applies the update OVER the base, so the update's copy probably wins"
  warn "  and these edits may have NO visible effect in game:"
  printf '     %s\n' "${shadowed[@]:0:8}"
  [ ${#shadowed[@]} -gt 8 ] && printf '     … and %d more\n' "$(( ${#shadowed[@]} - 8 ))"
  warn "  If the mod doesn't show up in game, copy it into the -UPDATE folder instead."
fi

report_catalog
ok "Revert with: scripts/40_apply_mods.sh --revert"
