#!/usr/bin/env bash
# DeckBorne self-update. Downloads the latest release and applies it over this tree.
#
#     ./install.sh update            check, then update if a newer release exists
#     ./install.sh update --force    apply the latest release even if not newer
#     ./install.sh update --check    report only, change nothing
#
# Never touches game-pkg/, payloads/mods/, logs/ or savefiles/ — the release tarball
# does not contain them. Workshop settings live in $HOME and are untouched.
#
# Restarting the UI afterwards is the UI's job, not this script's.
#
# Env: DECKBORNE_ALLOW_DEV_UPDATE=1  permit running against a dev checkout
#      DECKBORNE_UPDATE_BASE=<url>   override the release download base (testing)
set -euo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "${DECKBORNE_UPDATE_REEXEC:-0}" != 1 ]; then
  _safe="$(mktemp -t deckborne-update.XXXXXX.sh)"
  cp "${BASH_SOURCE[0]}" "$_safe"
  chmod +x "$_safe"
  export DECKBORNE_UPDATE_REEXEC=1
  export DECKBORNE_UPDATE_ORIGIN="$_here"
  exec bash "$_safe" "$@"
fi

source "${DECKBORNE_UPDATE_ORIGIN:-$_here}/lib.sh"
load_env

TARBALL="DeckBorne.tar.gz"
BASE="${DECKBORNE_UPDATE_BASE:-https://github.com/$DECKBORNE_REPO/releases/latest/download}"
STAGE="$DECKBORNE_ROOT/.update-tmp"
UI_DIR="$DECKBORNE_ROOT/payloads/ui"
SKIP_TOP=(game-pkg logs savefiles)
SKIP_PAYLOAD=(mods ui shadps4)
HAVE_RSYNC=0
command -v rsync >/dev/null 2>&1 && HAVE_RSYNC=1

mode="apply"
force=0
for a in "$@"; do
  case "$a" in
    --check) mode="check" ;;
    --force) force=1 ;;
    "") ;;
    *) die "unknown argument '$a' — expected --check or --force" ;;
  esac
done

_sweep() { rm -rf "$STAGE" 2>/dev/null || true; }
_on_signal() { _sweep; exit 130; }
trap _sweep EXIT
trap _on_signal INT TERM

step "DeckBorne self-update"
[ "$HAVE_RSYNC" = 1 ] || warn "rsync not found — falling back to copy+rename"

refuse_dev_tree() {
  [ "${DECKBORNE_ALLOW_DEV_UPDATE:-0}" = 1 ] && return 0
  local found=()
  [ -d "$DECKBORNE_ROOT/.git" ]      && found+=(".git/")
  [ -e "$DECKBORNE_ROOT/CLAUDE.md" ] && found+=("CLAUDE.md")
  [ -d "$DECKBORNE_ROOT/.venv-ui" ]  && found+=(".venv-ui/")
  [ ${#found[@]} -eq 0 ] && return 0
  die "this looks like a DEVELOPMENT checkout, not an install: found ${found[*]}
     Updating would overwrite your working copy with the last published release.
     None of those ship in the release tarball, which is how we can tell.
     Override with:  DECKBORNE_ALLOW_DEV_UPDATE=1 ./install.sh update"
}

free_mb() { df -Pm "$1" 2>/dev/null | awk 'NR==2{print $4}'; }

require_headroom() {
  local need_mb=320 have
  have="$(free_mb "$DECKBORNE_ROOT")"
  [ -n "$have" ] || { warn "could not read free space — continuing"; return 0; }
  [ "$have" -ge "$need_mb" ] || die "not enough free space where DeckBorne lives:
     have ${have} MB, need ~${need_mb} MB (download + extract + the outgoing AppImage)"
  ok "space: ${have} MB free"
}

_json_field() {
  printf '%s' "$1" | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: print(''); raise SystemExit
v=d.get('$2','')
print('1' if v is True else '' if v is False else v)
" 2>/dev/null || true
}

release_tag=""
report_versions() {
  local out err avail
  out="$(python3 "$DECKBORNE_ROOT/scripts/check_update.py" --json 2>/dev/null || true)"
  if [ -z "$out" ]; then
    [ "$force" = 1 ] || die "could not run the update check"
    warn "update check unavailable — continuing because --force was given"
    return 0
  fi
  err="$(_json_field "$out" error)"
  release_tag="$(_json_field "$out" latest)"
  avail="$(_json_field "$out" update_available)"
  if [ -n "$err" ]; then
    [ "$force" = 1 ] || die "update check failed: $err"
    warn "update check failed ($err) — continuing because --force was given"
    return 0
  fi
  ok "installed v$DECKBORNE_VERSION · latest ${release_tag:-unknown}"
  if [ "$avail" != 1 ]; then
    if [ "$mode" = check ]; then ok "already up to date"; exit 0; fi
    if [ "$force" != 1 ]; then ok "already up to date — nothing to do"; exit 0; fi
    warn "not newer, but --force was given"
  fi
}

download() {
  mkdir -p "$STAGE"
  step "Downloading $TARBALL"
  curl -fL --progress-bar -o "$STAGE/$TARBALL" "$BASE/$TARBALL" \
    || die "could not download $BASE/$TARBALL — is there a published release?"
  tar -tzf "$STAGE/$TARBALL" >/dev/null 2>&1 || die "downloaded archive is corrupt"
  ok "archive verified ($(du -h "$STAGE/$TARBALL" | cut -f1))"
}

extract() {
  mkdir -p "$STAGE/new"
  tar -xzf "$STAGE/$TARBALL" -C "$STAGE/new" --strip-components=1
  [ -f "$STAGE/new/install.sh" ]     || die "archive has no install.sh — refusing to apply"
  [ -s "$STAGE/new/scripts/lib.sh" ] || die "archive has no scripts/lib.sh — refusing to apply"
  ok "extracted"
}

_skip_top()     { local n="$1" s; for s in "${SKIP_TOP[@]}";     do [ "$n" = "$s" ] && return 0; done; return 1; }
_skip_payload() { local n="$1" s; for s in "${SKIP_PAYLOAD[@]}"; do [ "$n" = "$s" ] && return 0; done; return 1; }

_place() {
  local src="$1" destdir="$2"
  if [ "$HAVE_RSYNC" = 1 ]; then
    rsync -a "$src" "$destdir/"
  else
    local base tmp
    base="$(basename "$src")"
    tmp="$destdir/.replacing-$base.$$"
    rm -rf "$tmp"
    cp -a "$src" "$tmp"
    rm -rf "$destdir/$base.old.$$"
    [ -e "$destdir/$base" ] && mv -f "$destdir/$base" "$destdir/$base.old.$$"
    mv -f "$tmp" "$destdir/$base"
    rm -rf "$destdir/$base.old.$$"
  fi
}

apply_tool_files() {
  step "Applying tool files"
  local e b p pb
  for e in "$STAGE/new"/* "$STAGE/new"/.[!.]*; do
    [ -e "$e" ] || continue
    b="$(basename "$e")"
    if _skip_top "$b"; then log "  keeping your $b/"; continue; fi
    if [ "$b" = payloads ]; then
      mkdir -p "$DECKBORNE_ROOT/payloads"
      for p in "$e"/* "$e"/.[!.]*; do
        [ -e "$p" ] || continue
        pb="$(basename "$p")"
        if _skip_payload "$pb"; then log "  keeping your payloads/$pb/"; continue; fi
        _place "$p" "$DECKBORNE_ROOT/payloads"
      done
      continue
    fi
    _place "$e" "$DECKBORNE_ROOT"
  done
  chmod +x "$DECKBORNE_ROOT/install.sh" "$DECKBORNE_ROOT/uninstall.sh" \
           "$DECKBORNE_ROOT/ui/run.sh" "$DECKBORNE_ROOT/DeckBorne.desktop" 2>/dev/null || true
  chmod +x "$DECKBORNE_ROOT"/scripts/*.sh "$DECKBORNE_ROOT"/scripts/*.py 2>/dev/null || true
  sync
  ok "tool files applied"
}

verify_applied() {
  local got
  [ -s "$DECKBORNE_ROOT/scripts/lib.sh" ] || die "scripts/lib.sh is missing or empty after the update"
  [ -s "$DECKBORNE_ROOT/install.sh" ]     || die "install.sh is missing or empty after the update"
  bash -n "$DECKBORNE_ROOT/install.sh" 2>/dev/null || die "install.sh does not parse after the update"
  python3 -m py_compile "$DECKBORNE_ROOT/steam/add_shortcut.py" 2>/dev/null \
    || die "steam/add_shortcut.py does not parse after the update"
  got="$(grep -m1 'DECKBORNE_VERSION=' "$DECKBORNE_ROOT/config/deckborne.env" 2>/dev/null \
         | sed -E 's/.*:-([^}"]+).*/\1/')"
  ok "verified — config reports v${got:-unknown}"
}

swap_appimage() {
  local new stamp cur
  new="$(ls "$STAGE/new"/payloads/ui/*.AppImage 2>/dev/null | head -1 || true)"
  if [ -z "$new" ]; then log "release carries no UI AppImage — nothing to swap"; return 0; fi
  mkdir -p "$UI_DIR"
  step "Swapping the UI AppImage"
  stamp="$(date +%s 2>/dev/null || echo new)"
  cp -a "$new" "$UI_DIR/.incoming-$stamp.AppImage"
  chmod +x "$UI_DIR/.incoming-$stamp.AppImage"
  sync
  cur="$UI_DIR/$(basename "$new")"
  if [ -e "$cur" ]; then
    mv -f "$cur" "$UI_DIR/.outgoing-$stamp.AppImage" \
      || die "could not move the running AppImage aside"
  fi
  mv -f "$UI_DIR/.incoming-$stamp.AppImage" "$cur" \
    || die "could not put the new AppImage in place"
  sync
  ok "AppImage replaced"
}

sweep_outgoing() {
  local f n=0
  for f in "$UI_DIR"/.outgoing-*.AppImage "$UI_DIR"/.incoming-*.AppImage; do
    [ -e "$f" ] || continue
    rm -f "$f" 2>/dev/null && n=$((n + 1)) || true
  done
  [ "$n" -gt 0 ] && log "swept $n leftover AppImage file(s)"
  return 0
}

refuse_dev_tree
sweep_outgoing
report_versions

if [ "$mode" = check ]; then
  ok "a newer release is available — run:  ./install.sh update"
  exit 0
fi

require_headroom
download
extract
apply_tool_files
verify_applied
swap_appimage
_sweep

ok "DeckBorne updated to ${release_tag:-the latest release}."
