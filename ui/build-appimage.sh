#!/usr/bin/env bash
# Build the self-contained DeckBorne UI AppImage.
#
# RUN THIS ON AN x86-64 LINUX MACHINE — the Steam Deck itself (Desktop Mode) is the
# intended build host. The AppImage is architecture-specific; whatever arch you build on
# is the arch it runs on. Building on the aarch64 dev box produces an aarch64 AppImage,
# which is only good for validating the packaging (not for the Deck).
#
# The result — one file, payloads/ui/DeckBorneUI-<arch>.AppImage — bundles Python + Qt6 +
# PySide6 + the QML/art/font assets. It installs NOTHING on the user's Deck and leaves no
# trace: it self-mounts, runs, unmounts (same model as shadPS4's AppImage).
#
# Needs: internet (one-time, to fetch the base Python AppImage + PySide6 + appimagetool),
# python3 with venv, and FUSE (present on SteamOS). Nothing is installed system-wide;
# the build venv lives in a temp dir and is removed afterwards.
#
#   bash ui/build-appimage.sh
#
set -euo pipefail

# Pack via extract-and-run so the build works on hosts without FUSE too (harmless where
# FUSE is present, e.g. the Deck). Only affects the build tool; the produced AppImage is a
# normal one that runs via FUSE on the Deck.
export APPIMAGE_EXTRACT_AND_RUN=1

PYVER="${DECKBORNE_UI_PYVER:-3.11}"     # bundled Python version
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(dirname "$here")"
recipe="$here/appimage"
outdir="$repo/payloads/ui"
arch="$(uname -m)"

say() { printf '\n\033[1;35m==>\033[0m %s\n' "$*"; }

# Build in a temp dir on a real (exec-capable, symlink-capable) filesystem — NOT the
# exFAT USB, where venvs and AppImage tooling break.
work="$(mktemp -d "${TMPDIR:-/tmp}/deckborne-uibuild.XXXXXX")"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

say "DeckBorne UI AppImage build  (arch=$arch, python=$PYVER)"
command -v python3 >/dev/null || { echo "python3 not found"; exit 1; }

say "Creating build venv (python-appimage)…"
python3 -m venv "$work/venv"
"$work/venv/bin/python" -m pip install -q --upgrade pip
"$work/venv/bin/python" -m pip install -q python-appimage

# Stage the UI payload as a clean tree named `ui` (entrypoint expects $APPDIR/ui/main.py).
say "Staging UI payload…"
stage="$work/stage"
mkdir -p "$stage/ui"
cp "$here"/main.py "$here"/backend.py "$here"/icon.png "$stage/ui/"
cp -r "$here/qml" "$stage/ui/qml"
cp -r "$here/fonts" "$stage/ui/fonts"
mkdir -p "$stage/ui/art"
# only the runtime art the UI actually loads (skip the .odt logo source)
cp "$here/art"/*.jpg "$stage/ui/art/" 2>/dev/null || true
find "$stage/ui" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true

say "Building AppImage (downloads base Python + PySide6 on first run)…"
mkdir -p "$outdir"
# NB: appdir (recipe) must precede -x — its nargs=+ would otherwise swallow the positional.
( cd "$work" && "$work/venv/bin/python-appimage" build app \
    "$recipe" -p "$PYVER" -n DeckBorneUI -x "$stage/ui" )

# python-appimage names the output from the .desktop `Name` (DeckBorne), not -n.
img="$(ls "$work"/*.AppImage 2>/dev/null | head -1)"
[ -n "$img" ] || { echo "build produced no AppImage"; exit 1; }
chmod +x "$img"
mv -f "$img" "$outdir/"
final="$outdir/$(basename "$img")"

say "Done."
printf '  built: %s  (%s)\n' "$final" "$(du -h "$final" | cut -f1)"
printf '  test it:  DECKBORNE_ROOT=%s %s --mock\n' "$repo" "$final"
