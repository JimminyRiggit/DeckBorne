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
#
# NOT `set -e`, and no `exec` until we know something works. DeckBorne.desktop runs this
# with Terminal=false, so a failure here is INVISIBLE — the window just never appears.
# Every attempt is appended to logs/ui-launch.log and total failure raises a GUI dialog.
#
# The old version probed with `"$appimage" --appimage-version` and treated success as
# "this will run". It is not: the bundled runtime answers --appimage-version without
# mounting anything, so the probe passes on a host where the FUSE mount then fails, and
# the exec that followed had no fallback left. Attempt the real thing, then fall back to
# APPIMAGE_EXTRACT_AND_RUN=1, which needs no FUSE at all.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(dirname "$here")"
export DECKBORNE_ROOT="${DECKBORNE_ROOT:-$repo}"

launch_log="$repo/logs/ui-launch.log"
mkdir -p "$repo/logs" 2>/dev/null || true
note() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo '?')" "$*" \
    >> "$launch_log" 2>/dev/null || true
}
fail() {
  note "GIVING UP: $*"
  sync 2>/dev/null || true
  if command -v kdialog >/dev/null 2>&1; then
    kdialog --title "DeckBorne" --error "$*" >/dev/null 2>&1
  elif command -v zenity >/dev/null 2>&1; then
    zenity --error --title="DeckBorne" --text="$*" >/dev/null 2>&1
  fi
  exit 1
}

launch() {
  local img="$1" rc; shift
  note "try: $img"
  "$img" "$@" 2>>"$launch_log"; rc=$?
  [ "$rc" = 0 ] && return 0
  note "  exit $rc — retrying without FUSE (APPIMAGE_EXTRACT_AND_RUN=1)"
  APPIMAGE_EXTRACT_AND_RUN=1 "$img" "$@" 2>>"$launch_log"; rc=$?
  [ "$rc" = 0 ] && return 0
  note "  exit $rc"
  return 1
}

arch="$(uname -m)"
appimage="$repo/payloads/ui/DeckBorne-$arch.AppImage"
note "launch: root=$repo arch=$arch args=$*"

if [ -f "$appimage" ]; then
  note "appimage: $appimage ($(stat -c%s "$appimage" 2>/dev/null || echo '?') bytes)"
  launch "$appimage" "$@" && exit 0

  # The stick may be mounted noexec (can't run a binary off it), so stage a copy on a
  # tmpfs (exec-capable, cleared on logout — no permanent footprint) and run that.
  cache="${XDG_RUNTIME_DIR:-/tmp}/deckborne"
  note "staging a copy to $cache"
  if mkdir -p "$cache" 2>/dev/null &&
     { cp -u "$appimage" "$cache/" 2>/dev/null || cp -f "$appimage" "$cache/" 2>/dev/null; }; then
    chmod +x "$cache/$(basename "$appimage")" 2>/dev/null || true
    launch "$cache/$(basename "$appimage")" "$@" && exit 0
  else
    note "  could not stage a copy (no space in $cache?)"
  fi
else
  note "no AppImage at $appimage"
fi

# Dev fallback: local virtualenv (aarch64 dev box, or before the AppImage is built).
py="$repo/.venv-ui/bin/python"
[ -x "$py" ] || py=python3
note "falling back to: $py $here/main.py"
"$py" "$here/main.py" "$@" 2>>"$launch_log" && exit 0
note "  python fallback exited $?"

fail "DeckBorne could not start.

Tried the bundled app:
$appimage

Then the Python fallback:
$py

The reason is in this log:
$launch_log"
