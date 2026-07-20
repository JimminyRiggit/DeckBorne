#!/usr/bin/env bash
# DeckBorne — one-line bootstrap for Steam Deck Desktop Mode.
#
#     curl -fsSL https://raw.githubusercontent.com/JimminyRiggit/DeckBorne/main/scripts/bootstrap.sh | bash
#
# Lands a ready-to-run DeckBorne folder on the Deck's Desktop. It does NOT install
# anything — the user still has to drop their own game dump in and launch the UI. This
# script only replaces the "carry the tool on a USB stick" step.
#
# Env overrides (all optional):
#   DECKBORNE_DEST=<dir>   where to install      (default ~/Desktop/DeckBorne)
#   DECKBORNE_TAG=<tag>    pin a release         (default: latest)
#   DECKBORNE_NO_UI=1      skip the UI AppImage  (CLI-only install, ~5MB)
#
# NB this script runs BEFORE the repo exists, so it cannot source scripts/lib.sh.
# It is deliberately standalone and dependency-free: curl + tar + coreutils, all of
# which ship with SteamOS. Keep it that way.
set -euo pipefail

REPO="JimminyRiggit/DeckBorne"
DEST="${DECKBORNE_DEST:-$HOME/Desktop/DeckBorne}"
TAG="${DECKBORNE_TAG:-latest}"

# Release assets are published by scripts/build-release.sh under these exact names.
# GitHub's /releases/latest/download/<asset> redirect means we never need the API or
# jq (not guaranteed on SteamOS) just to resolve "newest".
TARBALL="DeckBorne.tar.gz"
UI_ASSET="DeckBorne-x86_64.AppImage"

if [ "$TAG" = latest ]; then
  BASE="https://github.com/$REPO/releases/latest/download"
else
  BASE="https://github.com/$REPO/releases/download/$TAG"
fi

# --- output helpers (mirror lib.sh's vocabulary so the two read alike) -------------
if [ -t 1 ]; then B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; N=$'\033[0m'
else B=""; G=""; Y=""; R=""; N=""; fi
step() { printf '%s==>%s %s\n' "$B" "$N" "$*"; }
ok()   { printf '%s  ok%s %s\n' "$G" "$N" "$*"; }
warn() { printf '%swarn%s %s\n' "$Y" "$N" "$*" >&2; }
die()  { printf '%s fail%s %s\n' "$R" "$N" "$*" >&2; exit 1; }

# --- preflight --------------------------------------------------------------------
step "DeckBorne bootstrap"

for c in curl tar mkdir; do
  command -v "$c" >/dev/null || die "missing required command: $c"
done

# Warn, don't fail. Someone staging a stick from another Linux box is a legitimate use.
if [ -r /etc/os-release ] && grep -qi steamos /etc/os-release; then
  ok "SteamOS detected"
else
  warn "Not SteamOS — continuing, but DeckBorne targets the Steam Deck in Desktop Mode."
fi

# The UI AppImage and the shadPS4 emulator are both x86-64. On anything else we can
# still lay the folder down (useful for prepping a stick), but say so plainly.
ARCH="$(uname -m)"
WANT_UI=1
[ "${DECKBORNE_NO_UI:-0}" = 1 ] && WANT_UI=0
if [ "$ARCH" != x86_64 ] && [ "$WANT_UI" = 1 ]; then
  warn "Host arch is '$ARCH'; the UI AppImage is x86-64 and won't run here. Skipping it."
  warn "The folder will still be usable — copy it to a Deck, or run ./install.sh there."
  WANT_UI=0
fi

# --- fetch ------------------------------------------------------------------------
# Everything lands in a temp dir first. A half-finished download must never leave a
# broken folder on the user's Desktop, and must never touch an existing install.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

step "Downloading DeckBorne ($TAG)"
curl -fL --progress-bar -o "$TMP/$TARBALL" "$BASE/$TARBALL" \
  || die "could not download $BASE/$TARBALL — is there a published release yet?"
tar -tzf "$TMP/$TARBALL" >/dev/null 2>&1 || die "downloaded archive is corrupt"
ok "tool archive verified"

if [ "$WANT_UI" = 1 ]; then
  step "Downloading the installer UI"
  if curl -fL --progress-bar -o "$TMP/$UI_ASSET" "$BASE/$UI_ASSET"; then
    ok "UI downloaded"
  else
    # Not fatal: install.sh is a complete CLI installer on its own.
    warn "UI download failed — falling back to CLI. Run ./install.sh in the folder below."
    WANT_UI=0
  fi
fi

# --- install ----------------------------------------------------------------------
# Extracting OVER an existing folder is deliberate and safe by construction: the
# tarball contains only tracked tool files, so a user's game-pkg/ (~30GB) and their
# downloaded payloads/mods/ are never in it and cannot be clobbered. That makes
# re-running this command a legitimate way to update in place.
if [ -e "$DEST" ]; then
  [ -d "$DEST" ] || die "$DEST exists and is not a directory"
  step "Updating existing install at $DEST"
  warn "your game-pkg/ and payloads/mods/ are left untouched"
else
  step "Installing to $DEST"
fi

mkdir -p "$DEST"
tar -xzf "$TMP/$TARBALL" -C "$DEST" --strip-components=1

if [ "$WANT_UI" = 1 ]; then
  mkdir -p "$DEST/payloads/ui"
  mv "$TMP/$UI_ASSET" "$DEST/payloads/ui/$UI_ASSET"
  chmod +x "$DEST/payloads/ui/$UI_ASSET"
fi

# The folders the user is expected to fill. Creating them up front turns "where do I
# put this?" into an obvious answer, and preflight's error message names game-pkg/.
mkdir -p "$DEST/game-pkg" "$DEST/payloads/mods"

# Scripts arrive from tar without reliable exec bits; the .desktop needs +x before
# Plasma will offer to launch it rather than open it in a text editor.
chmod +x "$DEST/install.sh" "$DEST/uninstall.sh" "$DEST/ui/run.sh" \
         "$DEST/DeckBorne.desktop" 2>/dev/null || true
chmod +x "$DEST"/scripts/*.sh 2>/dev/null || true

ok "DeckBorne installed to $DEST"

# --- what to do next --------------------------------------------------------------
# Deliberately NOT auto-running install.sh: preflight hard-fails without a game dump,
# and the user has to supply that themselves. Ending on a clear instruction beats
# ending on someone else's error message.
cat <<EOF

${B}Next steps${N}

  1. Copy your Bloodborne .pkg files into:
       ${B}$DEST/game-pkg/${N}
     (base game, plus the v1.09 update if you have it — filenames don't matter)

  2. If you want the DeckBorne profile, it ${B}requires${N} the Vertex Explosion Fix mod.
     Download it and drop the extracted folder into:
       ${B}$DEST/payloads/mods/${N}
     See the "Adding mods" section of README.md. Vanilla needs no mods.

  3. Start the installer:
EOF

if [ "$WANT_UI" = 1 ]; then
  cat <<EOF
       double-click ${B}DeckBorne.desktop${N} in $DEST
       (or run: ${B}$DEST/ui/run.sh${N})
EOF
else
  cat <<EOF
       ${B}cd "$DEST" && ./install.sh${N}
EOF
fi

echo
