#! /bin/bash
# AppImage entrypoint: run the bundled DeckBorne UI with the bundled Python.
# The UI payload is bundled at $APPDIR/ui via `python-appimage build app -x <ui>`.
# Locate the bundled interpreter by glob rather than a templated version string
# (the {{python}} substitution is unreliable, and there is no python/python3 symlink).
PYBIN=$(ls "$APPDIR"/opt/*/bin/python3.* 2>/dev/null | grep -v -- '-config' | head -1)
exec "$PYBIN" "$APPDIR/ui/main.py" "$@"
