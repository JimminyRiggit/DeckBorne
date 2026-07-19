#!/usr/bin/env bash
# Launch the DeckBorne UI.
#
#   ui/run.sh              open the window
#   ui/run.sh --mock       fake a run (dev preview — click through without touching Steam)
#   ui/run.sh --shot X.png render once to a PNG and exit (headless preview)
#
# Picks the runtime automatically:
#   * Production (the Deck): the self-contained AppImage in payloads/ui/ — bundles
#     Python + Qt + PySide6, installs nothing.
#   * Dev box: the local .venv-ui (PySide6) if no matching AppImage is present.
# Either way DECKBORNE_ROOT points the UI at the pipeline (install.sh) on this stick.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(dirname "$here")"
export DECKBORNE_ROOT="${DECKBORNE_ROOT:-$repo}"

appimage="$repo/payloads/ui/DeckBorne-$(uname -m).AppImage"
if [ -f "$appimage" ]; then
  # If the stick is mounted noexec (can't run a binary off it), stage a copy on a
  # tmpfs (exec-capable, cleared on logout — no permanent footprint) and run that.
  if "$appimage" --appimage-version >/dev/null 2>&1; then
    exec "$appimage" "$@"
  fi
  cache="${XDG_RUNTIME_DIR:-/tmp}/deckborne"
  mkdir -p "$cache"
  cp -u "$appimage" "$cache/" 2>/dev/null || cp -f "$appimage" "$cache/"
  chmod +x "$cache/$(basename "$appimage")"
  exec "$cache/$(basename "$appimage")" "$@"
fi

# Dev fallback: local virtualenv (aarch64 dev box, or before the AppImage is built).
py="$repo/.venv-ui/bin/python"
[ -x "$py" ] || py=python3
exec "$py" "$here/main.py" "$@"
