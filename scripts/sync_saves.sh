#!/usr/bin/env bash
# One-way copy of Bloodborne save data, in the direction the user asked for.
#
#   --export   shadPS4  ->  $DECKBORNE_ROOT/savefiles/<save-title-id>/
#   --import   savefiles ->  shadPS4
#
# There is deliberately NO timestamp comparison. "Newer wins" cannot express "put THIS
# save on the Deck": a save carried in from another machine is usually older than the one
# already on the device, and whether it even looks older depends on how it was copied.
# The destination is backed up to a dated .bak first, and the copy is verified afterwards.
#
# Emulator side : $SHADPS4_USER_DIR/home/<user>/savedata/<save-title-id>/, located by
#                 finding real save slots (userdata####/backup####), never by name alone.
#                 The save-title-id is NOT the disc title-id — see GAME_SAVE_TITLE_ID.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"; load_env

direction=""
case "${1:-}" in
  --export|export) direction="export" ;;
  --import|import) direction="import" ;;
  *) die "usage: sync_saves.sh --export|--import
     --export   copy the Deck's save out to DeckBorne/savefiles/
     --import   copy DeckBorne/savefiles/ onto the Deck
   There is no two-way mode: pick the direction you mean." ;;
esac

step "Save data — $direction"

stamp="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo backup)"
store_root="$DECKBORNE_ROOT/savefiles"

slot_parents() {
  [ -d "$1" ] || return 0
  find "$1" -maxdepth 6 -type f \( -name 'userdata[0-9]*' -o -name 'backup[0-9]*' \) \
    -printf '%h\n' 2>/dev/null | sort -u
}

title_dirs_with_slots() {
  local d
  while IFS= read -r d; do [ -n "$d" ] && dirname "$d"; done < <(slot_parents "$1") | sort -u
}

pick_title_dir() {
  local -n _out="$1"; shift
  local dirs=("$@") d
  _out=""
  [ "${#dirs[@]}" -eq 0 ] && return 0
  for d in "${dirs[@]}"; do
    [ "$(basename "$d")" = "$GAME_SAVE_TITLE_ID" ] && { _out="$d"; return 0; }
  done
  for d in "${dirs[@]}"; do
    if compgen -G "$d/$GAME_SAVE_DIR_GLOB" >/dev/null 2>&1; then _out="$d"; return 0; fi
  done
  [ "${#dirs[@]}" -eq 1 ] && _out="${dirs[0]}"
  return 0
}

emulator_savedata_root() {
  local d
  for d in "$SHADPS4_USER_DIR"/home/*/savedata; do
    [ -d "$d" ] && { printf '%s' "$d"; return 0; }
  done
  printf '%s' "$SHADPS4_USER_DIR/home/1000/savedata"
}

mapfile -t emu_titles < <(title_dirs_with_slots "$SHADPS4_USER_DIR/home")
pick_title_dir emu "${emu_titles[@]}"

mapfile -t store_titles < <(title_dirs_with_slots "$store_root")
pick_title_dir store "${store_titles[@]}"

if [ -z "$emu" ] && [ "${#emu_titles[@]}" -gt 0 ]; then
  warn "shadPS4 holds save data for several titles and none looks like Bloodborne:"
  for d in "${emu_titles[@]}"; do warn "    $d"; done
  warn "Set GAME_SAVE_TITLE_ID to the right one and run this again."
  die "refusing to guess which save is Bloodborne's"
fi

if [ "$direction" = "export" ]; then
  [ -n "$emu" ] || die "shadPS4 has no Bloodborne save to export.
   Nothing was found under $SHADPS4_USER_DIR/home/*/savedata/
   Play the game and save once, then export."
  save_id="$(basename "$emu")"
  src="$emu"
  dst="${store:-$store_root/$save_id}"
  src_label="shadPS4"
  dst_label="DeckBorne"
else
  [ -n "$store" ] || die "there is no save in DeckBorne/savefiles to import.
   Nothing was found under $store_root
   Put a save there (or run --export first), then import."
  save_id="$(basename "$store")"
  src="$store"
  dst="${emu:-$(emulator_savedata_root)/$save_id}"
  src_label="DeckBorne"
  dst_label="shadPS4"
fi

damaged="$(find "$src" -type f \( -name 'userdata[0-9]*' -o -name 'backup[0-9]*' \) -empty 2>/dev/null | wc -l)"
if [ "$damaged" -gt 0 ]; then
  warn "The $src_label copy contains $damaged empty save slot(s):"
  find "$src" -type f \( -name 'userdata[0-9]*' -o -name 'backup[0-9]*' \) -empty -printf '    %P\n' 2>/dev/null
  warn "Copying that over a good save would destroy it. Nothing has been changed."
  die "refusing to $direction a damaged save"
fi

ok "save title: $save_id  (disc title is $GAME_TITLE_ID — they differ, this is expected)"
ok "from : $src_label  $src"
ok "to   : $dst_label  $dst"

backup_side() { # backup_side <dir> <label> — 0 only if a backup really exists afterwards
  local dir="$1" label="$2"
  [ -d "$dir" ] && [ -n "$(ls -A "$dir" 2>/dev/null)" ] || return 1
  local bak="${dir%/}.bak-$stamp"
  if cp -a "$dir" "$bak" 2>/dev/null; then
    ok "backed up the existing $label save → $(basename "$bak")"
    return 0
  fi
  warn "could not back up the $label side before writing"
  return 1
}

copy_all() { # copy_all <src> <dst>
  local n=0
  mkdir -p "$2"
  if command -v rsync >/dev/null 2>&1; then
    n="$(rsync -ac --itemize-changes "$1"/ "$2"/ 2>/dev/null | grep -c '^[<>]' || true)"
  else
    cp -a "$1"/. "$2"/ 2>/dev/null || true
    n="$(find "$1" -type f 2>/dev/null | wc -l)"
  fi
  printf '%s' "$n"
}

have_sums=0
command -v sha256sum >/dev/null 2>&1 && have_sums=1

file_sum() { # file_sum <path>
  sha256sum "$1" 2>/dev/null | cut -d' ' -f1
}

verify_copy() { # verify_copy <src> <dst>
  local rel bad=0 a b
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    if [ ! -e "$2/$rel" ]; then
      warn "MISSING at the destination: $rel"; bad=$((bad+1)); continue
    fi
    if [ "$(stat -c %s "$1/$rel" 2>/dev/null)" != "$(stat -c %s "$2/$rel" 2>/dev/null)" ]; then
      warn "TRUNCATED at the destination: $rel"; bad=$((bad+1)); continue
    fi
    [ "$have_sums" = 1 ] || continue
    a="$(file_sum "$1/$rel")"; b="$(file_sum "$2/$rel")"
    if [ -n "$a" ] && [ "$a" != "$b" ]; then
      warn "CONTENT DIFFERS at the destination: $rel"; bad=$((bad+1))
    fi
  done < <(cd "$1" 2>/dev/null && find . -type f -printf '%P\n' 2>/dev/null)
  printf '%s' "$bad"
}

pending_changes() { # pending_changes <src> <dst>
  command -v rsync >/dev/null 2>&1 || { printf 1; return 0; }
  rsync -acn --itemize-changes "$1"/ "$2"/ 2>/dev/null | grep -c '^[<>]' || true
}

pending="$(pending_changes "$src" "$dst")"
backed_up=0
if [ "$pending" -gt 0 ]; then
  backup_side "$dst" "$dst_label" && backed_up=1
else
  ok "Nothing to copy — the two sides already match; no backup taken"
fi

copied="$(copy_all "$src" "$dst")"

sync 2>/dev/null || true

bad="$(verify_copy "$src" "$dst")"
if [ "$bad" != 0 ]; then
  warn "The $src_label side is untouched."
  [ "$backed_up" = 1 ] && warn "The $dst_label side was backed up as .bak-$stamp before writing."
  die "$direction did NOT complete cleanly — $bad file(s) missing or truncated"
fi

total="$(find "$src" -type f 2>/dev/null | wc -l)"
ok "Copied $copied changed file(s); $total file(s) now match on both sides"
if [ "$have_sums" = 1 ]; then
  ok "Verified: every file present at the destination with a matching checksum, and flushed to disk"
else
  warn "sha256sum is unavailable, so the copy was verified by size only — and every save"
  warn "  slot is the same fixed size, so that cannot tell two different saves apart."
  ok "Verified: every file present at the destination at the same size, and flushed to disk"
fi
if [ "$backed_up" = 1 ]; then
  ok "$direction complete. The previous $dst_label save is kept as .bak-$stamp"
else
  ok "$direction complete. Nothing was overwritten, so no backup was needed"
fi
