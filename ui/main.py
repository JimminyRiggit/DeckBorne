#!/usr/bin/env python3
"""DeckBorne installer UI — PySide6 + QtQuick (QML) front-end.

Run on the dev box to preview the window (mock install driver):

    ui/run.sh            # or: .venv-ui/bin/python ui/main.py

The window is a thin front-end: it shells out to the existing scripts/NN_*.sh
pipeline (wiring lands after the shell is signed off). Artwork comes from
payloads/artwork/ — the same Bloodborne art the Steam tile uses.
"""
from __future__ import annotations

import os
import sys
from pathlib import Path

from PySide6.QtCore import QUrl
from PySide6.QtGui import QGuiApplication, QIcon
from PySide6.QtQml import QQmlApplicationEngine

from backend import Installer

REPO = Path(__file__).resolve().parent.parent
UI = Path(__file__).resolve().parent
ARTWORK = REPO / "payloads" / "artwork"      # Steam grid art (icon)
ART = UI / "art"                             # user-provided UI art (background)
FONTS = UI / "fonts"                         # bundled fonts (ships to the Deck)
BG_IMAGE = ART / "bloodborne-game-artwork-vn-1920x1080.jpg"
WORKSHOP_IMAGE = ART / "the-workshop.jpg"
DECKBORNE_FONT = FONTS / "Fleshandblood-MVA5x.ttf"
QML_MAIN = UI / "qml" / "Main.qml"


def main() -> int:
    app = QGuiApplication(sys.argv)
    app.setApplicationName("DeckBorne")
    app.setOrganizationName("DeckBorne")
    # icon: prefer the bundled ui/icon.png (ships inside the AppImage), fall back to the
    # Steam grid art in the repo (dev box).
    for icon_png in (UI / "icon.png", ARTWORK / "icon.png"):
        if icon_png.exists():
            app.setWindowIcon(QIcon(str(icon_png)))
            break

    engine = QQmlApplicationEngine()

    # --mock (or DECKBORNE_UI_MOCK=1) fakes a run for dev-box preview.
    installer = Installer(mock="--mock" in sys.argv)

    ctx = engine.rootContext()
    ctx.setContextProperty("installer", installer)
    # file:// URLs so QML can reference the bundled assets directly
    ctx.setContextProperty("bgImageUrl", QUrl.fromLocalFile(str(BG_IMAGE)))
    ctx.setContextProperty("workshopBgUrl", QUrl.fromLocalFile(str(WORKSHOP_IMAGE)))
    ctx.setContextProperty("deckborneFontUrl", QUrl.fromLocalFile(str(DECKBORNE_FONT)))
    ctx.setContextProperty("artworkDir", QUrl.fromLocalFile(str(ARTWORK) + os.sep))
    # --open N forces option card N expanded (screenshot preview of the hover state)
    preview_open = -1
    if "--open" in sys.argv:
        preview_open = int(sys.argv[sys.argv.index("--open") + 1])
    ctx.setContextProperty("previewOpen", preview_open)

    engine.load(QUrl.fromLocalFile(str(QML_MAIN)))
    if not engine.rootObjects():
        print("ERROR: failed to load QML", file=sys.stderr)
        return 1

    # --shot <path>: render the window once, save a PNG, quit. Dev-box preview aid.
    if "--shot" in sys.argv:
        from PySide6.QtCore import QTimer
        from PySide6.QtQuick import QQuickWindow

        out = sys.argv[sys.argv.index("--shot") + 1]
        win = engine.rootObjects()[0]

        # --running: kick off an install so the shot shows the in-progress state
        delay = 900
        if "--running" in sys.argv:
            win.setProperty("showProgress", True)
            QTimer.singleShot(150, installer.startDeckBorne)
            delay = 2600

        def _grab():
            # root is a QQuickWindow under the hood; call via the class so PySide
            # dispatches grabWindow() even though the wrapper is typed QWindow.
            img = QQuickWindow.grabWindow(win)
            img.save(out)
            print(f"wrote {out}")
            app.quit()

        # let the async images + fontloader settle, then grab (override with env)
        delay = int(os.environ.get("DECKBORNE_SHOT_DELAY", delay))
        QTimer.singleShot(delay, _grab)

    return app.exec()


if __name__ == "__main__":
    raise SystemExit(main())
