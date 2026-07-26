"""DeckBorne UI backend.

The Installer QObject drives the real pipeline (``install.sh`` / its ``uninstall``
and ``collect`` sub-commands) through a QProcess, and reports progress to QML via
properties + a stage model.

Two drivers:
  * REAL (default): launches ``bash install.sh`` with the chosen profile and parses
    ``@@DBUI`` stage markers install.sh emits (gated on DECKBORNE_UI=1 so terminal
    runs never see them). This is the shipping path — it runs on the Deck.
  * MOCK (``DECKBORNE_UI_MOCK=1`` or ``--mock``): a timer that fakes a run, so the
    window can be previewed/iterated on the aarch64 dev box where the real installer
    can't run (no emulator, preflight refuses non-Deck hardware).

Testing hook: ``DECKBORNE_UI_ENTRY`` overrides the entry script path, so the real
QProcess path can be exercised against a marker-emitting stub off-Deck.
"""
from __future__ import annotations

import json
import os
import re
import shutil
import signal
import subprocess
from pathlib import Path

from PySide6.QtCore import (
    QAbstractListModel,
    QModelIndex,
    QObject,
    QProcess,
    QProcessEnvironment,
    Qt,
    QTimer,
    Signal,
    Slot,
    Property,
)

REPO = Path(__file__).resolve().parent.parent

# Where the DeckBorne pipeline lives (install.sh, scripts/, config/). Resolved in order:
#   1. DECKBORNE_ROOT — set by ui/run.sh / the .desktop launcher.
#   2. Derived from $APPIMAGE — when the packed AppImage is double-clicked directly, its
#      runtime exports its own path; it ships at <root>/payloads/ui/X.AppImage, so the
#      pipeline root is three parents up. Lets the AppImage work with no launcher wrapper.
#   3. REPO — the dev-box repo root (running main.py straight from a checkout).
def _resolve_pipeline_root() -> Path:
    if os.environ.get("DECKBORNE_ROOT"):
        return Path(os.environ["DECKBORNE_ROOT"])
    appimage = os.environ.get("APPIMAGE")
    if appimage:
        return Path(appimage).resolve().parent.parent.parent  # payloads/ui/X → root
    return REPO

PIPELINE_ROOT = _resolve_pipeline_root()

# Stages per action, as (checklist-label, friendly-message). KEEP IN SYNC with the
# VISIBLE stages of install.sh's run_list per DECKBORNE_PROFILE — install.sh emits
# `@@DBUI STAGE <idx> <state>` (1-based) and the UI updates row <idx>-1, so order must
# match. Stages listed in install.sh's UI_HIDDEN_STAGES (e.g. 35_apply_patches.sh) run
# but emit no marker and are NOT numbered, so they must NOT appear here. The friendly
# message is shown to the user (raw install.sh log lines are NOT surfaced — they go to
# the run log only). A label starting with "Extract" triggers the rotating quote panel.
STAGES_VANILLA = [
    ("Preflight checks", "Validating if this is gonna cook…"),
    ("Install shadPS4 emulator", "Installing the emulator…"),
    ("Extract Bloodborne (~30 GB)", "Extracting Bloodborne — this is the long one."),
    ("Apply vanilla config (30 FPS)", "Applying Vanilla config…"),
    ("Restore stock game files",
     "Making sure the game files are stock — Vanilla ships no mods, so anything a "
     "previous DeckBorne install layered on is being undone."),
    ("Create Steam tile",
     "Noble Hunter. Steam Client will restart twice to build the tile and library entries "
     "on your behalf. The game will soft-launch for 15 seconds as part of this ritual."
     "\n\n"
     "Your patience is what separates us from the beasts that prowl these hallowed streets "
     "of Yharnam. Best not to forget that."),
]
STAGES_DECKBORNE = [
    ("Preflight checks", "Validating if this is gonna cook…"),
    ("Install shadPS4 emulator", "Installing the emulator…"),
    ("Extract Bloodborne (~30 GB)", "Extracting Bloodborne — this is the long one."),
    ("Apply config & patches", ""),
    # Filled in at click time by stages_deckborne() — the text depends on what is actually
    # sitting in payloads/mods/ right now. Placeholder only, never shown as-is.
    ("Community mods", ""),
    ("Create Steam tile",
     "Noble Hunter. Steam Client will restart twice to build the tile and library entries "
     "on your behalf. The game will soft-launch for 15 seconds as part of this ritual."
     "\n\n"
     "Your patience is what separates us from the beasts that prowl these hallowed streets "
     "of Yharnam. Best not to forget that."),
]

# Nexus download folders carry a trailing "-<modid>-<version parts>-<unix timestamp>"
# (e.g. "MOAL-107-1-1-0-1728330824"). Users drop them in unrenamed, and the raw name reads
# as noise in a progress list — strip the machine part for display ONLY. The folder itself
# is never renamed: stage 40 finds mods by iterating the directory, and the id in
# config/mods.catalog is matched against the real name.
_MOD_NAME_SUFFIX = re.compile(r"-\d+(?:-\d+)*-\d{9,}$")

MODS_FLAVOUR = (
    "Hhhhmmm. snuck in your own workshop tools, did you? "
    "No matter, all the better for the hunt."
)


def _detected_mods() -> list[str]:
    """Directory names in payloads/mods/ — i.e. exactly what stage 40 will iterate.

    Mirrors stage 40's own glob (`"$mods_src"/*/`): directories only, no dotfiles. Kept
    deliberately dumb — it reports what is THERE, not what will successfully apply. A mod
    whose layout can't be placed is still counted here and then reported skipped by stage
    40, which is honest; claiming a count the install then contradicts would not be.
    """
    try:
        return sorted(
            p.name for p in (PIPELINE_ROOT / "payloads" / "mods").iterdir()
            if p.is_dir() and not p.name.startswith(".")
        )
    except OSError:
        return []


def _mods_stage() -> tuple[str, str]:
    """The (label, message) for the community-mods row, based on what's installed now.

    ⚠ Returns a row either way — never None. The stage list is index-aligned with
    install.sh's `@@DBUI STAGE <idx>` markers, so dropping this row when no mods are
    present would shift every later row and mislabel the Steam-tile stage.
    """
    mods = _detected_mods()
    if not mods:
        return (
            "Community mods (none installed)",
            "No mods found — mods are user-supplied, and none have been added. "
            "Skipping this step.",
        )
    plural = "mod" if len(mods) == 1 else "mods"
    return (
        f"Apply community {plural} ({len(mods)})",
        MODS_FLAVOUR,
    )


DECKBORNE_TARGETS: dict[str, dict[str, str]] = {
    "deck30": {
        "row": "Apply config & patches (30 FPS · 800p)",
        "message": "Applying the DeckBorne config — 30 FPS at 800p.",
        "headline": "Installing · DeckBorne 30 FPS",
    },
    "deck60": {
        "row": "Apply config & patches (60 FPS · 800p)",
        "message": "Applying the DeckBorne config — 60 FPS at 800p. This one is a beta: the "
                   "frame rate may not hold on a standard Deck.",
        "headline": "Installing · DeckBorne 60 FPS",
    },
    "desktop": {
        "row": "Apply config & patches (60 FPS · 1080p)",
        "message": "Applying the DeckBorne config — 60 FPS at 1080p, for desktop hardware.",
        "headline": "Installing · DeckBorne Desktop",
    },
}
DEFAULT_TARGET = "deck30"


def stages_deckborne(target: str = DEFAULT_TARGET) -> list[tuple[str, str]]:
    """STAGES_DECKBORNE with the config row named for `target` and the mods row resolved.

    Built per click rather than at import: the mods row depends on what is in
    payloads/mods/ right now (the user drops folders in with a file manager, not through
    this UI), and the config row depends on which experience was just clicked.
    """
    spec = DECKBORNE_TARGETS.get(target, DECKBORNE_TARGETS[DEFAULT_TARGET])
    rows = []
    for label, msg in STAGES_DECKBORNE:
        if label == "Community mods":
            rows.append(_mods_stage())
        elif label == "Apply config & patches":
            rows.append((spec["row"], spec["message"]))
        else:
            rows.append((label, msg))
    return rows


UNINSTALL_STAGES = [
    ("Removing emulator, game files & Steam tile",
     "Good Work, Yharnam has survived another beastly hunt. Until next time, good hunter."
     "\n\n"
     "Uninstalling Emulator, ISO, and Steam Tiles/Art. Steam Client will reboot as part "
     "of uninstall."),
]
COLLECT_STAGES = [("Snapshot logs & config", "Collecting logs & config…")]

# Closing line shown once a run succeeds. Install sends the user off to play; the
# other paths are not "go play" moments, so they carry their own.
DONE_INSTALL = "Complete — Bloodborne is now available to launch from your Steam library. Happy Hunting."
DONE_UNINSTALL = "Uninstall completed — until the next Hunt."
DONE_COLLECT = "Logs & config collected."

_MARKER = re.compile(r"@@DBUI\s+STAGE\s+(\d+)\s+(start|done|fail)\b")
_SUBPROG = re.compile(r"@@DBUI\s+SUBPROGRESS\s+([0-9.]+)")
_ERROR = re.compile(r"@@DBUI\s+ERROR\s+(.+)$")
# Overrides the current stage's friendly message. For a stage that can do materially
# different things under one label — stage 20 extracts OR relocates an existing install —
# where the static row text would otherwise describe the wrong operation.
_STATUS = re.compile(r"@@DBUI\s+STATUS\s+(.+)$")
# Names the corner sub-progress readout, which otherwise only appears for the extraction
# (that one is gated on the quote panel, and a relocation deliberately turns quotes off).
# Cleared on every stage change so a label can never outlive the work it describes.
_SUBLABEL = re.compile(r"@@DBUI\s+SUBLABEL\s+(.+)$")
_MOD = re.compile(r"@@DBUI\s+MOD\s+(\d+)\s+(\d+)\s+(.+)$")
_ANSI = re.compile(r"\x1b\[[0-9;]*m")

GENERIC_FAILURE = "Something went wrong — see the run log on the USB."

# How long the stage subtree gets to run its cleanup traps (kill the copy worker, sweep
# .move-tmp) after SIGTERM, before the group is SIGKILLed. A relocation's trap has to stop
# a `cp` and remove a temp dir, so this is deliberately not the old 2s.
CANCEL_GRACE_MS = 8000


def _leads_own_group(pid: int) -> int:
    """The child's process-group id, but ONLY if it leads a group of its own.

    Returns 0 otherwise, which is the safety property that matters: a QProcess child
    inherits our process group by default, so signalling "the child's group" without this
    check would signal the UI itself. Reads /proc rather than trusting that setsid ran —
    the group is only used when the kernel confirms the child is its own leader.
    """
    try:
        with open(f"/proc/{pid}/stat", "rb") as fh:
            data = fh.read().decode("utf-8", "replace")
    except OSError:
        return 0
    try:
        # comm can contain spaces and parens, so fields are read after the LAST ')'.
        after = data[data.rindex(")") + 1:].split()
        pgid = int(after[2])            # state, ppid, pgrp
    except (ValueError, IndexError):
        return 0
    if pgid != pid or pgid == os.getpgrp():
        return 0
    return pgid


def _signal_group(pid: int, sig: int) -> bool:
    pgid = _leads_own_group(pid)
    if not pgid:
        return False
    try:
        os.killpg(pgid, sig)
    except OSError:
        return False
    return True


def _unescape(s: str) -> str:
    out, i = [], 0
    while i < len(s):
        if s[i] == "\\" and i + 1 < len(s):
            nxt = s[i + 1]
            if nxt == "n":
                out.append("\n")
                i += 2
                continue
            if nxt == "\\":
                out.append("\\")
                i += 2
                continue
        out.append(s[i])
        i += 1
    return "".join(out)

# --- storage devices --------------------------------------------------------
# Detection lives in scripts/detect_storage.py, NOT here: the pipeline needs the same
# answer (stage 00 validates the chosen root with --check) and two implementations would
# drift. Shelling out also means detection can be fixed by editing the USB, without the
# AppImage rebuild that any change to THIS file requires — and that rebuild has to happen
# on the Deck, since the dev box is aarch64.
DETECT_STORAGE = "scripts/detect_storage.py"

# Must match DECKBORNE_STORAGE_FILE in config/deckborne.env — it is how a previously
# chosen device is pre-selected when the window opens.
STORAGE_STATE = Path.home() / ".local" / "share" / "DeckBorne" / "storage_root"


def _gb(n: int) -> str:
    return f"{n / 1000**3:.0f} GB"


# The AppImage carries its own backend.py but NOT the pipeline, so a newly-built UI can
# find itself pointed at an older DECKBORNE_ROOT with no detect_storage.py. Blocking every
# install on that would be a worse failure than the feature is a win — fall back to the
# pre-feature behaviour: one device, $HOME, exactly where installs used to go.
def _fallback_devices() -> list[dict]:
    home = str(Path.home())
    try:
        st = os.statvfs(home)
        free, total = st.f_bavail * st.f_frsize, st.f_blocks * st.f_frsize
    except OSError:
        free = total = 0
    return [{
        "root": home, "name": "Internal storage", "kind": "internal",
        "mountpoint": home, "device": "", "fstype": "",
        "total_bytes": total, "free_bytes": free,
        "writable": True, "fs_ok": True, "enough_space": True, "usable": True,
        "installed": None, "is_installer_medium": False,
        "games_dir": str(Path(home) / "Games" / "shadps4"),
        "note": "",
    }]


def detect_storage() -> list[dict]:
    try:
        out = subprocess.run(
            ["python3", str(PIPELINE_ROOT / DETECT_STORAGE), "--json"],
            capture_output=True, text=True, timeout=20, check=True,
            env={**os.environ, "DECKBORNE_ROOT": str(PIPELINE_ROOT)},
        ).stdout
        devices = json.loads(out).get("devices", [])
    except (OSError, subprocess.SubprocessError, json.JSONDecodeError, ValueError):
        devices = []
    return devices or _fallback_devices()


def remembered_storage_root() -> str:
    try:
        return STORAGE_STATE.read_text().strip()
    except OSError:
        return ""


# StorageModel roles. Same naming caution as StageModel below — nothing here may collide
# with a built-in QML Item property.
_SNAME, _SROOT, _SDETAIL, _SUSABLE, _SNOTE, _SSELECTED, _SKIND = (
    Qt.UserRole + 10, Qt.UserRole + 11, Qt.UserRole + 12, Qt.UserRole + 13,
    Qt.UserRole + 14, Qt.UserRole + 15, Qt.UserRole + 16,
)


class StorageModel(QAbstractListModel):
    def __init__(self, parent=None):
        super().__init__(parent)
        self._rows: list[dict] = []
        self._selected = -1

    def roleNames(self):
        return {
            _SNAME: b"name", _SROOT: b"root", _SDETAIL: b"detail",
            _SUSABLE: b"usable", _SNOTE: b"note", _SSELECTED: b"selected",
            _SKIND: b"kind",
        }

    def rowCount(self, parent=QModelIndex()):
        return 0 if parent.isValid() else len(self._rows)

    def data(self, index, role=Qt.DisplayRole):
        if not index.isValid():
            return None
        d = self._rows[index.row()]
        return {
            _SNAME: d["name"],
            _SROOT: d["root"],
            _SDETAIL: self._detail(d),
            # A full device is offered but not selectable: the user can see WHY it is
            # not an option, which a missing row cannot tell them.
            _SUSABLE: bool(d["usable"] and d["enough_space"]),
            _SNOTE: d["note"],
            _SSELECTED: index.row() == self._selected,
            _SKIND: d["kind"],
        }.get(role)

    @staticmethod
    def _detail(d: dict) -> str:
        bits = [f"{_gb(d['free_bytes'])} free of {_gb(d['total_bytes'])}", d["fstype"]]
        if d["installed"]:
            bits.append("Bloodborne installed here")
        if d["is_installer_medium"]:
            bits.append("installer drive")
        return "  ·  ".join(bits)

    def set_devices(self, devices: list[dict], prefer: str = ""):
        self.beginResetModel()
        self._rows = devices
        self._selected = -1
        self.endResetModel()

        def pick(test) -> bool:
            for i, d in enumerate(self._rows):
                if d["usable"] and d["enough_space"] and test(d):
                    self.select(i)
                    return True
            return False

        # The default is the root filesystem. It is overridden ONLY by a device that
        # already holds the game: selecting internal there would silently propose
        # relocating ~30GB off the user's SD card just because they opened the window.
        if pick(lambda d: d["installed"] and d["root"] == prefer):
            return
        if pick(lambda d: d["installed"]):
            return
        if pick(lambda d: d["kind"] == "internal"):
            return
        pick(lambda d: True)

    def select(self, row: int) -> bool:
        if not (0 <= row < len(self._rows)):
            return False
        if not (self._rows[row]["usable"] and self._rows[row]["enough_space"]):
            return False
        old, self._selected = self._selected, row
        for r in {old, row}:
            if 0 <= r < len(self._rows):
                idx = self.index(r, 0)
                self.dataChanged.emit(idx, idx, [_SSELECTED])
        return True

    def selected_device(self) -> dict | None:
        if 0 <= self._selected < len(self._rows):
            return self._rows[self._selected]
        return None

    def count(self):
        return len(self._rows)


# StageModel roles (role is "stageState", not "state" — QML Item has a built-in
# `state` that role-injection would collide with).
_LABEL, _STATE = Qt.UserRole + 1, Qt.UserRole + 2


class StageModel(QAbstractListModel):
    def __init__(self, parent=None):
        super().__init__(parent)
        self._rows: list[dict] = []

    def roleNames(self):
        return {_LABEL: b"label", _STATE: b"stageState"}

    def rowCount(self, parent=QModelIndex()):
        return 0 if parent.isValid() else len(self._rows)

    def data(self, index, role=Qt.DisplayRole):
        if not index.isValid():
            return None
        row = self._rows[index.row()]
        return {_LABEL: row["label"], _STATE: row["state"]}.get(role)

    def set_labels(self, labels: list[str]):
        self.beginResetModel()
        self._rows = [{"label": t, "state": "pending"} for t in labels]
        self.endResetModel()

    def set_state(self, row: int, state: str):
        if 0 <= row < len(self._rows):
            self._rows[row]["state"] = state
            idx = self.index(row, 0)
            self.dataChanged.emit(idx, idx, [_STATE])

    def count(self):
        return len(self._rows)


class Installer(QObject):
    busyChanged = Signal()
    progressChanged = Signal()
    subProgressChanged = Signal()
    subLabelChanged = Signal()
    indeterminateChanged = Signal()
    statusChanged = Signal()
    headlineChanged = Signal()
    quotingChanged = Signal()
    failedChanged = Signal()
    storageChanged = Signal()
    finished = Signal(bool, str)  # success, message

    def __init__(self, mock: bool = False, parent=None):
        super().__init__(parent)
        self._mock = mock or os.environ.get("DECKBORNE_UI_MOCK") == "1"
        self._busy = False
        self._progress = 0.0
        self._sub_progress = 0.0        # 0..1 within the current stage (extraction readout)
        self._sub_label = ""            # names that readout; empty hides it
        self._indeterminate = False
        self._status = "Ready."
        self._headline = "Choose an experience"
        self._quoting = False           # True during the Extract stage → UI shows quotes
        self._failed = False
        self._error = ""
        self._done_message = DONE_INSTALL   # set per run; see _start_process/_mock_begin
        self._stages = StageModel(self)
        self._storage = StorageModel(self)
        self.refreshStorage()

        self._total = 0
        self._proc: QProcess | None = None
        self._buf = ""

        # mock driver state
        self._timer = QTimer(self)
        self._timer.timeout.connect(self._mock_tick)
        self._labels: list[str] = []
        self._messages: list[str] = []
        self._cur = 0
        self._sub = 0

    # ---- properties ----
    @Property(bool, notify=busyChanged)
    def busy(self):
        return self._busy

    @Property(float, notify=progressChanged)
    def progress(self):
        return self._progress

    @Property(float, notify=subProgressChanged)
    def subProgress(self):          # progress of the current stage alone (0..1)
        return self._sub_progress

    @Property(str, notify=subLabelChanged)
    def subLabel(self):
        return self._sub_label

    @Property(bool, notify=indeterminateChanged)
    def indeterminate(self):
        return self._indeterminate

    @Property(str, notify=statusChanged)
    def status(self):
        return self._status

    @Property(str, notify=headlineChanged)
    def headline(self):
        return self._headline

    @Property(bool, notify=quotingChanged)
    def quoting(self):
        return self._quoting

    @Property(bool, notify=failedChanged)
    def failed(self):
        return self._failed

    @Property(QObject, constant=True)
    def stages(self):
        return self._stages

    @Property(QObject, constant=True)
    def storage(self):
        return self._storage

    @Property(str, notify=storageChanged)
    def storageRoot(self):
        d = self._storage.selected_device()
        return d["root"] if d else ""

    @Property(str, notify=storageChanged)
    def storageName(self):
        d = self._storage.selected_device()
        return d["name"] if d else ""

    # The install buttons gate on this. False means every detected device is
    # unwritable, non-POSIX or too full — starting a run would only waste the user's
    # time reaching stage 00's identical refusal.
    @Property(bool, notify=storageChanged)
    def storageReady(self):
        return self._storage.selected_device() is not None

    @Property(str, notify=storageChanged)
    def storageWarning(self):
        d = self._storage.selected_device()
        if d is None:
            if self._storage.count() == 0:
                return "No storage devices detected."
            return ("No usable install location — see the notes below. An SD card must "
                    "be formatted for Linux (ext4); Steam Deck: Settings → System → "
                    "Format SD Card.")
        if d["kind"] != "internal":
            return ("Installing to removable storage — the game will only launch while "
                    "this device is plugged in.")
        return ""

    # ---- setters ----
    def _set(self, attr, val, sig):
        if getattr(self, attr) != val:
            setattr(self, attr, val)
            sig.emit()

    def _set_progress(self, v):
        self._set("_progress", max(0.0, min(1.0, v)), self.progressChanged)

    # ---- stage bookkeeping (labels + friendly messages + quote flag) ----
    def _apply_stages(self, stages):
        self._labels = [s[0] for s in stages]
        self._messages = [s[1] for s in stages]
        self._stages.set_labels(self._labels)
        self._total = len(stages)

    def _enter_stage(self, idx):
        self._cur = idx
        self._set("_sub_progress", 0.0, self.subProgressChanged)
        self._set("_sub_label", "", self.subLabelChanged)
        if 0 <= idx < self._stages.count():
            self._stages.set_state(idx, "running")
        if 0 <= idx < len(self._messages):
            self._set("_status", self._messages[idx], self.statusChanged)
        quoting = idx < len(self._labels) and self._labels[idx].lower().startswith("extract")
        self._set("_quoting", quoting, self.quotingChanged)

    # ---- storage (QML) ----
    @Slot()
    def refreshStorage(self):
        self._storage.set_devices(detect_storage(), prefer=remembered_storage_root())
        self.storageChanged.emit()

    @Slot(int)
    def selectStorage(self, row: int):
        if self._storage.select(row):
            self.storageChanged.emit()

    # ---- actions (QML) ----
    @Slot()
    def startVanilla(self):
        self._start_install("vanilla", STAGES_VANILLA, "Installing · Vanilla")

    @Slot(str)
    def startDeckBorne(self, target: str = DEFAULT_TARGET):
        if target not in DECKBORNE_TARGETS:
            target = DEFAULT_TARGET
        self._start_install(
            "deckborne", stages_deckborne(target),
            DECKBORNE_TARGETS[target]["headline"], target=target,
        )

    @Slot()
    def startUninstall(self):
        # No per-stage markers from the uninstall path yet: show one working row.
        self._start_process(
            ["uninstall"], {}, UNINSTALL_STAGES, "Uninstalling", indeterminate=True,
            done_message=DONE_UNINSTALL,
        )

    @Slot()
    def startCollect(self):
        self._start_process(
            ["collect"], {}, COLLECT_STAGES, "Collecting logs", indeterminate=True,
            done_message=DONE_COLLECT,
        )

    @Slot()
    def cancel(self):
        if not self._busy:
            return
        if self._proc is not None:
            self._error = "Cancelled by user."
            pid = int(self._proc.processId() or 0)
            if not (pid and _signal_group(pid, signal.SIGTERM)):
                self._proc.terminate()
            if not self._proc.waitForFinished(CANCEL_GRACE_MS):
                if not (pid and _signal_group(pid, signal.SIGKILL)):
                    self._proc.kill()
                self._proc.waitForFinished(2000)
            return  # _on_finished handles the rest
        # mock
        self._timer.stop()
        if self._cur < self._stages.count():
            self._stages.set_state(self._cur, "failed")
        self._set("_quoting", False, self.quotingChanged)
        self._set("_busy", False, self.busyChanged)
        self._set("_headline", "Cancelled", self.headlineChanged)
        self._set("_status", "Cancelled.", self.statusChanged)
        self.finished.emit(False, "Cancelled by user.")

    # ---- install dispatch ----
    # ⚠ Only the INSTALL path passes DECKBORNE_STORAGE_ROOT. Uninstall and collect must
    # act on wherever the game actually IS, which is the location stage 00 recorded — not
    # whatever happens to be selected in the window. Passing it there would let a user
    # who swapped SD cards "uninstall" a device that never held the game, and report
    # success for it.
    def _start_install(self, profile, stages, headline, target=""):
        env = {"DECKBORNE_PROFILE": profile}
        if target:
            env["DECKBORNE_TARGET"] = target
        root = self.storageRoot
        if root:
            env["DECKBORNE_STORAGE_ROOT"] = root
        if self._mock:
            self._mock_begin(stages, headline)
        else:
            self._start_process([], env, stages, headline)

    # ---- REAL driver (QProcess) ----
    def _start_process(self, args, extra_env, stages, headline, indeterminate=False,
                       done_message=DONE_INSTALL):
        if self._busy:
            return
        if self._mock:                       # mock has no per-command args; fake it
            self._mock_begin(stages, headline, indeterminate, done_message)
            return

        self._done_message = done_message

        self._apply_stages(stages)
        self._cur = 0
        self._buf = ""
        self._error = ""
        self._set("_failed", False, self.failedChanged)
        self._set_progress(0.0)
        self._set("_indeterminate", indeterminate, self.indeterminateChanged)
        self._set("_busy", True, self.busyChanged)
        self._set("_headline", headline, self.headlineChanged)
        if stages:
            self._enter_stage(0)

        entry = os.environ.get("DECKBORNE_UI_ENTRY") or str(PIPELINE_ROOT / "install.sh")
        proc = QProcess(self)
        # Run under setsid so install.sh leads its own session, and Cancel can signal the
        # whole subtree. Qt's terminate()/kill() reach the single child pid only, which
        # never gets to the stage script or its `cp` — they orphan and run to completion,
        # finishing a relocation the user believes they stopped. PySide6 exposes no
        # childProcessModifier, so the wrapper is how the session gets created; whether it
        # worked is verified at signal time by _leads_own_group(), which falls back to
        # single-pid signals rather than ever signalling a group that could include us.
        argv = ["bash", entry, *args]
        setsid = shutil.which("setsid")
        proc.setProgram(setsid or argv[0])
        proc.setArguments(argv if setsid else argv[1:])
        proc.setWorkingDirectory(str(PIPELINE_ROOT))
        proc.setProcessChannelMode(QProcess.MergedChannels)
        env = QProcessEnvironment.systemEnvironment()
        env.insert("DECKBORNE_UI", "1")
        for k, v in extra_env.items():
            env.insert(k, v)
        proc.setProcessEnvironment(env)
        proc.readyReadStandardOutput.connect(self._on_output)
        proc.finished.connect(self._on_finished)
        proc.errorOccurred.connect(self._on_error)
        self._proc = proc
        proc.start()

    def _on_output(self):
        if self._proc is None:
            return
        self._buf += bytes(self._proc.readAllStandardOutput()).decode("utf-8", "replace")
        while "\n" in self._buf:
            line, self._buf = self._buf.split("\n", 1)
            self._handle_line(line)

    def _handle_line(self, line: str):
        sp = _SUBPROG.search(line)
        if sp:
            # fine-grained progress WITHIN the current stage (e.g. extraction): the bar
            # advances from stage-start to stage-done instead of freezing.
            frac = max(0.0, min(1.0, float(sp.group(1))))
            self._set("_sub_progress", frac, self.subProgressChanged)
            if self._total:
                self._set_progress((self._cur + frac) / self._total)
            return
        md = _MOD.search(line)
        if md:
            idx, total = md.group(1), md.group(2)
            name = _MOD_NAME_SUFFIX.sub("", md.group(3).strip())
            base = self._messages[self._cur] if self._cur < len(self._messages) else ""
            self._set("_status", f"Applying {idx}/{total} - {name}\n\n{base}",
                      self.statusChanged)
            if self._total:
                frac = int(idx) / max(1, int(total))
                self._set("_sub_progress", frac, self.subProgressChanged)
                self._set_progress((self._cur + frac) / self._total)
            return
        sl = _SUBLABEL.search(line)
        if sl:
            self._set("_sub_label", _unescape(sl.group(1)).strip(), self.subLabelChanged)
            return
        st = _STATUS.search(line)
        if st:
            self._set("_status", _unescape(st.group(1)).strip(), self.statusChanged)
            # A relocation is not an extraction — drop the quote panel so the message
            # the stage just sent is the thing actually on screen.
            self._set("_quoting", False, self.quotingChanged)
            return
        er = _ERROR.search(line)
        if er:
            if not self._error:
                self._error = _unescape(er.group(1)).strip()
            return
        m = _MARKER.search(line)
        if m:
            idx, state = int(m.group(1)) - 1, m.group(2)
            if state == "start":
                self._enter_stage(idx)       # sets running + friendly message + quote flag
                if self._total:
                    self._set_progress(idx / self._total)
            elif state == "done":
                self._stages.set_state(idx, "done")
                if self._total:
                    self._set_progress((idx + 1) / self._total)
            elif state == "fail":
                self._stages.set_state(idx, "failed")
            return
        # Raw install.sh log lines are intentionally NOT surfaced to the UI — they go to
        # the run log only. The user sees the friendly per-stage message + quotes instead.

    def _on_error(self, err):
        if not self._error:
            self._error = f"Failed to launch the installer ({err})."
        self._set("_status", self._error, self.statusChanged)

    def _on_finished(self, code, _status):
        ok = code == 0
        # settle stage states to match the outcome
        if ok:
            for i in range(self._stages.count()):
                self._stages.set_state(i, "done")
            self._set_progress(1.0)
        elif self._cur < self._stages.count():
            self._stages.set_state(self._cur, "failed")
        fail_text = self._error or GENERIC_FAILURE
        self._set("_indeterminate", False, self.indeterminateChanged)
        self._set("_quoting", False, self.quotingChanged)
        self._set("_sub_label", "", self.subLabelChanged)
        self._set("_busy", False, self.busyChanged)
        self._set("_failed", not ok, self.failedChanged)
        self._set("_headline", "Done" if ok else "Failed", self.headlineChanged)
        self._set("_status", self._done_message if ok else fail_text, self.statusChanged)
        self._proc = None
        self.finished.emit(ok, self._done_message if ok else fail_text)

    # ---- MOCK driver (dev-box preview) ----
    _STEPS = 6

    def _mock_begin(self, stages, headline, indeterminate=False, done_message=DONE_INSTALL):
        if self._busy:
            return
        self._done_message = done_message
        self._apply_stages(stages)
        self._cur = 0
        self._sub = 0
        self._error = ""
        self._set("_failed", False, self.failedChanged)
        self._set_progress(0.0)
        self._set("_indeterminate", indeterminate, self.indeterminateChanged)
        self._set("_busy", True, self.busyChanged)
        self._set("_headline", headline, self.headlineChanged)
        if self._total:
            self._enter_stage(0)
        # linger on the Extract stage so the quote panel is visible in the preview
        self._timer.start(160)

    def _mock_tick(self):
        if self._cur >= self._total:
            return
        self._sub += 1
        # dwell longer on the extract stage (to show quotes rotating)
        steps = 40 if self._labels[self._cur].lower().startswith("extract") else self._STEPS
        frac = self._sub / steps
        self._set("_sub_progress", min(0.99, frac) if steps == 40 else frac, self.subProgressChanged)
        self._set_progress((self._cur + frac) / self._total)
        if self._sub >= steps:
            self._stages.set_state(self._cur, "done")
            self._cur += 1
            self._sub = 0
            if self._cur < self._total:
                self._enter_stage(self._cur)
            else:
                self._timer.stop()
                self._set_progress(1.0)
                self._set("_indeterminate", False, self.indeterminateChanged)
                self._set("_quoting", False, self.quotingChanged)
                self._set("_busy", False, self.busyChanged)
                self._set("_headline", "Done", self.headlineChanged)
                self._set("_status", self._done_message, self.statusChanged)
                self.finished.emit(True, self._done_message)
