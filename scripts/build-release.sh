#!/usr/bin/env bash
# Build the single DeckBorne release asset: DeckBorne.tar.gz
#
#   bash scripts/build-release.sh
#
# Produces DeckBorne.tar.gz = the tool files + the UI AppImage under payloads/ui/ — the
# single asset scripts/bootstrap.sh downloads. Run this ON THE DECK (x86-64): the UI
# AppImage is x86-64 and is built here by ui/build-appimage.sh.
#
# NO git required. A Deck deployment (USB stick or a bootstrap install) has no .git, so
# this packs the CURRENT folder directly, excluding the game dump, logs, user mods, the
# emulator payload, caches, internal notes, and — critically — the SteamGridDB API key.
# A deny-list can miss things, so a safety scan REFUSES to build if anything key-shaped
# survives into the staged tree.
#
# Env overrides:
#   DECKBORNE_REUSE_APPIMAGE=1   use the existing payloads/ui/*.AppImage, don't rebuild
#   DECKBORNE_ALLOW_NONX86=1     build anyway on non-x86 (produces a Deck-unusable UI)
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(dirname "$here")"
arch="$(uname -m)"

say()  { printf '\n\033[1;35m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ok\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarn\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mfail\033[0m %s\n' "$*" >&2; exit 1; }

cd "$repo"
for c in tar find mktemp du; do command -v "$c" >/dev/null || die "required command not found: $c"; done

if [ "$arch" != x86_64 ] && [ "${DECKBORNE_ALLOW_NONX86:-0}" != 1 ]; then
  die "arch is '$arch', not x86_64 — the bundled UI would not run on a Deck.
  Build releases on the Deck. To assemble anyway (testing only): DECKBORNE_ALLOW_NONX86=1"
fi

appimage="$repo/payloads/ui/DeckBorne-$arch.AppImage"

# --- 1. the UI AppImage -----------------------------------------------------
if [ "${DECKBORNE_REUSE_APPIMAGE:-0}" = 1 ] && [ -f "$appimage" ]; then
  ok "reusing existing $(basename "$appimage")"
else
  say "Building the UI AppImage…"
  bash "$repo/ui/build-appimage.sh"
fi
[ -f "$appimage" ] || die "no AppImage at $appimage after build"
ok "UI AppImage: $(basename "$appimage")  ($(du -h "$appimage" | cut -f1))"

# --- 2. stage a clean copy (git-free, deny-list) ----------------------------
say "Assembling DeckBorne.tar.gz…"
work="$(mktemp -d "${TMPDIR:-/tmp}/deckborne-release.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/DeckBorne"

# NEVER ship: the game dump, run logs, the user's mods, the emulator payload, python
# caches, editor/USB cruft, the release artifact itself, internal notes, and the API key.
# payloads/ui/*.AppImage is deliberately NOT excluded — that is what we are bundling.
tar -c -C "$repo" \
  --exclude='./.git' \
  --exclude='./.gitattributes' \
  --exclude='./.venv-ui' \
  --exclude='./.claude' \
  --exclude='./.usb-backup-*' \
  --exclude='./logs' \
  --exclude='./game-pkg' \
  --exclude='./savefiles' \
  --exclude='./payloads/shadps4' \
  --exclude='./payloads/mods/*' \
  --exclude='*__pycache__*' \
  --exclude='*.pyc' \
  --exclude='*.bak' \
  --exclude='*.deckborne.bak' \
  --exclude='*.log.raw' \
  --exclude='./.goutputstream-*' \
  --exclude='./DeckBorne.tar.gz' \
  --exclude='./config/steamgriddb.key' \
  --exclude='*.key' \
  --exclude='./CLAUDE.md' \
  --exclude='./mempalace.yaml' \
  --exclude='./entities.json' \
  . | tar -x -C "$work/DeckBorne"

mkdir -p "$work/DeckBorne/payloads/mods"; : > "$work/DeckBorne/payloads/mods/.gitkeep"
cat > "$work/DeckBorne/payloads/mods/PUT-MODS-HERE.txt" <<'MODHELP'
Drop mods in the same directory as this .txt file — one folder per mod. See the
"Adding mods" section of README.md. Mods are optional for Vanilla; the DeckBorne
profile requires the Vertex Explosion Fix mod (not shipped).
MODHELP
mkdir -p "$work/DeckBorne/payloads/ui"

# game-pkg/ is excluded (it holds the user's ~30GB dump), but the FOLDER must exist in the
# release so a direct-extract user knows where their .pkg files go. Ship it empty, with a
# loud placeholder that names itself in the folder listing.
mkdir -p "$work/DeckBorne/game-pkg"
cat > "$work/DeckBorne/game-pkg/PUT-GAME-PKG-FILES-HERE.txt" <<'PKGHELP'
Drop your Bloodborne .pkg files in the same directory as this .txt file — the base
game, plus the v1.09 (The Old Hunters) update if you have it. Filenames don't matter.
See the "What goes in game-pkg/" section of README.md. DeckBorne never provides these.
PKGHELP

# make sure the CURRENT AppImage is in, and no other-arch AppImage tagged along
cp -f "$appimage" "$work/DeckBorne/payloads/ui/$(basename "$appimage")"
find "$work/DeckBorne/payloads/ui" -name '*.AppImage' ! -name "$(basename "$appimage")" -delete

# --- 3. SAFETY: refuse to ship secrets --------------------------------------
leak="$(find "$work/DeckBorne" -type f \( -iname '*.key' -o -iname '*.pem' -o -iname 'id_rsa*' -o -iname '*.secret' \) 2>/dev/null)"
[ -z "$leak" ] || die "refusing to build — secret-looking files survived into the tarball:
$leak"

saves="$(find "$work/DeckBorne" -type f \( -name 'userdata[0-9]*' -o -name 'backup[0-9]*' \) 2>/dev/null)"
[ -z "$saves" ] || die "refusing to build — SAVE DATA survived into the tarball:
$saves"

# --- 4. archive + verify ----------------------------------------------------
out="$repo/DeckBorne.tar.gz"
tar -czf "$out" -C "$work" DeckBorne
sync "$out" 2>/dev/null || sync 2>/dev/null || true

# Capture the listing ONCE and grep a here-string — piping tar into `grep -q` trips
# pipefail (grep exits on first match, tar dies on SIGPIPE, pipeline reports failure).
listing="$(tar -tzf "$out" 2>/dev/null)" || die "produced archive is corrupt"
grep -q 'payloads/ui/.*\.AppImage' <<<"$listing" || die "the AppImage did not make it into the tarball"
grep -qi 'steamgriddb.key'        <<<"$listing" && die "API key leaked into the tarball — aborting"

say "Done."
printf '  built: %s  (%s)\n' "$out" "$(du -h "$out" | cut -f1)"
printf '  contains: %s files, incl. the bundled UI AppImage; no key, logs, dump, or mods\n' \
  "$(grep -vc '/$' <<<"$listing")"
cat <<EOF

  Publish it as a release asset (you handle the tag/push):

    git tag -a v0.1.0 -m "..."   &&   git push origin v0.1.0
    gh release create v0.1.0 "$out" --title v0.1.0 --notes "..."

  …or draft a release in the GitHub web UI for tag v0.1.0 and drag in DeckBorne.tar.gz.
  bootstrap.sh then serves it from /releases/latest/download/DeckBorne.tar.gz.
EOF
