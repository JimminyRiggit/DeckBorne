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

# ---- placement resolver -----------------------------------------------------
# GOAL: the user unzips a mod, drops the folder into payloads/mods/ exactly as it came
# out of the archive, and this figures out where those files belong. No hand re-rooting.
#
# The old resolver assumed a mod's root always maps to the GAME ROOT, and only unwrapped
# one level of `CoolMod v1.2/`. That misses the whole BB_Launcher / "modloader friendly"
# convention, where the mod's root maps to dvdroot_ps4 INSTEAD. Real example that cost a
# manual fix: `Vertex Explosion fix/parts/*.partsbnd.dcx` — one wrapper deep AND
# dvdroot-relative, so both assumptions were wrong at once and it was silently skipped.
#
# There are two independent unknowns, so we search BOTH instead of assuming either:
#   DEPTH  — how many wrapper folders the author nested the files under.
#   ANCHOR — which directory in the game the mod's root corresponds to.
# Then we let the installed game arbitrate: for each (root, anchor) pair, ask "do these
# files already exist under you?" The pair with the best hit ratio wins. That is evidence,
# not pattern-matching, so it also handles layouts nobody has seen yet.

# _anchor_candidates — where a mod tree could be rooted. DERIVED from the real game, not
# a hardcoded list, so an oddly-shaped dump still works. For Bloodborne this yields the
# game root plus dvdroot_ps4/ and sce_sys/ (the last is harmless — nothing scores on it).
_anchor_candidates() {
  printf '%s\n' "$game_root"
  find "$game_root" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort
}

# _mod_root_candidates <dir> — <dir>, then walk DOWN through single-subdirectory wrappers.
# Recursive, unlike the old one-level unwrap: authors nest arbitrarily
# (`Mod v1.2/Optional/Standard/parts/`). Stops at anything with files or >1 subdir — which
# is exactly what makes a MULTI-VARIANT mod (Optional/Blue + Optional/Red) stop early and
# score zero, rather than us silently picking a variant for the user. Depth-capped so a
# pathological tree can't spin.
_mod_root_candidates() {
  local d="$1" n=0 inner=()
  while [ "$n" -lt 8 ]; do
    printf '%s\n' "$d"
    shopt -s nullglob; inner=( "$d"/*/ ); shopt -u nullglob
    [ "${#inner[@]}" -eq 1 ] || break
    [ "$(find "$d" -maxdepth 1 -type f 2>/dev/null | wc -l)" -eq 0 ] || break
    d="${inner[0]%/}"
    n=$((n + 1))
  done
}

# _score_files <mod_root> <anchor> — echoes "<hits> <total>". The STRONG signal: how many
# of the mod's files already exist under this anchor. A file-overlay mod replaces existing
# game files, so a correct anchor scores near 100% and a wrong one scores ~0.
# Sampled (not exhaustive) to keep this fast on a mod with thousands of files; the sample
# is the first N paths in sort order, so it is deterministic and re-runs identically.
_MOD_SAMPLE=60
_score_files() {
  local root="$1" anchor="$2" hits=0 total=0 rel
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    total=$((total + 1))
    [ -e "$anchor/$rel" ] && hits=$((hits + 1))
  done < <(cd "$root" && find . -type f -printf '%P\n' 2>/dev/null | sort | head -n "$_MOD_SAMPLE")
  printf '%s %s' "$hits" "$total"
}

# _first_rel <mod_root> — the first file path in sort order, mod-root-relative. Used only
# as a stable probe for the equivalence check in the resolver; unwrapping a single-child
# directory doesn't change WHICH file this is, only how it's spelled, which is exactly the
# property that makes it a valid key.
_first_rel() {
  (cd "$1" && find . -type f -printf '%P\n' 2>/dev/null | sort | head -n 1)
}

# _score_names <mod_root> <anchor> — echoes a count. The WEAK fallback, for a mod that only
# ADDS files: nothing overlaps, so _score_files reads 0 everywhere and cannot choose. Match
# top-level NAMES instead (mod's `parts/` vs the game's `dvdroot_ps4/parts/`).
# Case-insensitive: PS4 filesystems and extractor output disagree on case.
_score_names() {
  local root="$1" anchor="$2" hits=0 e base seen=0
  for e in "$root"/*; do
    [ -e "$e" ] || continue
    # Capped: this is a heuristic, and one find per entry gets expensive on a root holding
    # hundreds of files. A dozen top-level names is more than enough to place a tree.
    [ "$seen" -lt 12 ] || break
    seen=$((seen + 1))
    base="$(basename "$e")"
    # -mindepth 1 is LOAD-BEARING: `find <dir> -maxdepth 1 -iname X` matches <dir> ITSELF at
    # depth 0. Without it, asking "does dvdroot_ps4/ exist inside game/dvdroot_ps4/?" answers
    # YES by self-match, inventing a bogus second placement and making the resolver refuse a
    # perfectly good mod as ambiguous. (Inherited from the old _entries_match, where it was
    # latent only because the game root's basename is a title id that never collides.)
    find "$anchor" -mindepth 1 -maxdepth 1 -iname "$base" -print -quit 2>/dev/null | grep -q . \
      && hits=$((hits + 1))
  done
  printf '%s' "$hits"
}

# _resolve_mod_placement <dir> — echoes "<src>|<prefix>|<signal>", or nothing if the layout
# can't be placed (caller reports a loud SKIP).
#   src     the directory to merge FROM
#   prefix  where it lands, RELATIVE TO THE GAME ROOT ("" or "dvdroot_ps4/")
#   signal  strong|weak — which evidence decided it, so the log can say
#
# ⚠ `prefix` is load-bearing. Every downstream consumer — the backup copy, added.list, the
# -UPDATE shadow check, the locale check, and `--revert` — is written in GAME-ROOT-relative
# paths. Returning a prefix (rather than merging straight into the anchor) means the merge
# loop can normalise back to game-root-relative and ALL of that keeps working untouched.
# Revert in particular would silently restore to the wrong depth otherwise.
#
# TWO PASSES, and the order is a PERFORMANCE decision, not a stylistic one. Scoring both
# signals for every pair took 7s on the real 144-file vertex-explosion mod on the dev box —
# `_score_names` spawns a find per top-level entry per pair, and at the deepest candidate
# root that is 144 entries x 3 anchors. The name pass is only ever needed when file
# matching finds nothing, so it now runs ONLY then. Common case: one cheap pass.
_resolve_mod_placement() {
  local d="$1" root anchor hits total ratio prefix key first
  local best_ratio=-1 best_root="" best_anchor="" best_ties=0 best_key=""
  local nbest=-1 nroot="" nanchor="" nties=0 nh nkey=""

  # PASS 1 — STRONG: do these files already exist under this anchor?
  while IFS= read -r root; do
    [ -n "$root" ] || continue
    first="$(_first_rel "$root")"          # once per root, not once per pair
    while IFS= read -r anchor; do
      [ -n "$anchor" ] || continue
      # EQUIVALENCE KEY, not identity. A mod already rooted at dvdroot_ps4/ matches as BOTH
      # (mod, game_root) AND (mod/dvdroot_ps4, game/dvdroot_ps4) — two descriptions of ONE
      # placement, since every byte lands in the same file either way. Keying the tie check
      # on the resolved DESTINATION of a fixed sample file collapses those, so only
      # genuinely different outcomes count as ambiguous.
      key="$anchor/$first"
      read -r hits total < <(_score_files "$root" "$anchor")
      [ "${total:-0}" -gt 0 ] || continue
      ratio=$(( hits * 100 / total ))
      if [ "$ratio" -gt "$best_ratio" ]; then
        best_ratio="$ratio"; best_root="$root"; best_anchor="$anchor"
        best_key="$key"; best_ties=1
      elif [ "$ratio" -eq "$best_ratio" ] && [ "$ratio" -gt 0 ] && [ "$key" != "$best_key" ]; then
        best_ties=$((best_ties + 1))
      fi
    done < <(_anchor_candidates)
  done < <(_mod_root_candidates "$d")

  # A clear majority of sampled files already exist under this anchor. 50% rather than a
  # higher bar because a partly-additive mod (replaces some files, adds others) is normal
  # and still unambiguous. A tie means two DIFFERENT destinations fit equally well — refuse.
  if [ "$best_ratio" -ge 50 ] && [ "$best_ties" -eq 1 ]; then
    prefix="${best_anchor#"$game_root"}"; prefix="${prefix#/}"
    [ -n "$prefix" ] && prefix="$prefix/"
    printf '%s|%s|strong' "$best_root" "$prefix"; return 0
  fi

  # PASS 2 — WEAK, only reached when pass 1 was inconclusive: an add-only mod overlaps
  # nothing, so match top-level directory NAMES instead. Announced as weak by the caller.
  while IFS= read -r root; do
    [ -n "$root" ] || continue
    first="$(_first_rel "$root")"
    while IFS= read -r anchor; do
      [ -n "$anchor" ] || continue
      key="$anchor/$first"
      nh="$(_score_names "$root" "$anchor")"
      # same equivalence collapsing as pass 1 — two depths, one destination, not a tie
      if [ "$nh" -gt "$nbest" ]; then
        nbest="$nh"; nroot="$root"; nanchor="$anchor"; nkey="$key"; nties=1
      elif [ "$nh" -eq "$nbest" ] && [ "$nh" -gt 0 ] && [ "$key" != "$nkey" ]; then
        nties=$((nties + 1))
      fi
    done < <(_anchor_candidates)
  done < <(_mod_root_candidates "$d")

  if [ "$nbest" -gt 0 ] && [ "$nties" -eq 1 ]; then
    prefix="${nanchor#"$game_root"}"; prefix="${prefix#/}"
    [ -n "$prefix" ] && prefix="$prefix/"
    printf '%s|%s|weak' "$nroot" "$prefix"; return 0
  fi
  return 1
}
# ---- end placement resolver -------------------------------------------------
# ⚠ The two marker comments above/below this block are load-bearing for testing: the
# resolver tests source it out of this file by awk range, so they exercise the SHIPPING
# code rather than a drifting copy. Keep both markers if you reorganise this file.

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

  if ! placement="$(_resolve_mod_placement "$mod")"; then
    warn "SKIPPED '$name' — couldn't work out where its files belong."
    warn "  it contains:  $(cd "$mod" && ls -A | head -5 | tr '\n' ' ')"
    warn "  game root has: $(cd "$game_root" && ls -A | head -5 | tr '\n' ' ')"
    warn "  This means its files matched nothing in the game at any depth, OR the mod"
    warn "  ships several alternative versions and we will not pick one for you."
    warn "  Fix: if there are variant folders (Optional/, 'Blue version/', …), move the"
    warn "  ONE you want to payloads/mods/<name>/ and re-run this stage."
    skipped=$((skipped + 1)); skipped_names+=( "$name" )
    continue
  fi
  IFS='|' read -r src prefix signal <<<"$placement"
  [ "$src" = "$mod" ] || log "  unwrapped to: ${src#"$mod"/}"
  log "  placing at: ${prefix:-<game root>}${signal:+  (matched on ${signal/strong/existing files})}"
  if [ "$signal" = weak ]; then
    warn "  '$name' adds files but replaces none, so its location was inferred from folder"
    warn "  NAMES alone. If it has no effect in game, this is the first thing to check."
  fi

  # Copy file-by-file so every overwrite is backed up first and every addition is
  # recorded. Slower than a blind rsync, but this is what makes revert real.
  while IFS= read -r rel_raw; do
    [ -n "$rel_raw" ] || continue
    # Normalise to a GAME-ROOT-relative path. Everything below — backup, added.list, the
    # shadow and locale checks, and --revert — speaks game-root-relative, so a mod anchored
    # at dvdroot_ps4 must be translated HERE and nowhere else.
    rel="$prefix$rel_raw"
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
    cp -a "$src/$rel_raw" "$dest"   # SOURCE is mod-relative; DEST is game-root-relative
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
