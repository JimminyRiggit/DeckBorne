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

import os
import re
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
    ("Apply config & patches (60 FPS)", "Applying the DeckBorne config…"),
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


def stages_deckborne() -> list[tuple[str, str]]:
    """STAGES_DECKBORNE with the mods row resolved against the current payloads/mods/.

    Built per click rather than at import so a mod added while the window is open is still
    reflected — the user drops folders in with a file manager, not through this UI.
    """
    return [_mods_stage() if label == "Community mods" else (label, msg)
            for label, msg in STAGES_DECKBORNE]


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
_MOD = re.compile(r"@@DBUI\s+MOD\s+(\d+)\s+(\d+)\s+(.+)$")
_ANSI = re.compile(r"\x1b\[[0-9;]*m")

GENERIC_FAILURE = "Something went wrong — see the run log on the USB."


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
    indeterminateChanged = Signal()
    statusChanged = Signal()
    headlineChanged = Signal()
    quotingChanged = Signal()
    failedChanged = Signal()
    finished = Signal(bool, str)  # success, message

    def __init__(self, mock: bool = False, parent=None):
        super().__init__(parent)
        self._mock = mock or os.environ.get("DECKBORNE_UI_MOCK") == "1"
        self._busy = False
        self._progress = 0.0
        self._sub_progress = 0.0        # 0..1 within the current stage (extraction readout)
        self._indeterminate = False
        self._status = "Ready."
        self._headline = "Choose an experience"
        self._quoting = False           # True during the Extract stage → UI shows quotes
        self._failed = False
        self._error = ""
        self._done_message = DONE_INSTALL   # set per run; see _start_process/_mock_begin
        self._stages = StageModel(self)

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
        if 0 <= idx < self._stages.count():
            self._stages.set_state(idx, "running")
        if 0 <= idx < len(self._messages):
            self._set("_status", self._messages[idx], self.statusChanged)
        quoting = idx < len(self._labels) and self._labels[idx].lower().startswith("extract")
        self._set("_quoting", quoting, self.quotingChanged)

    # ---- actions (QML) ----
    @Slot()
    def startVanilla(self):
        self._start_install("vanilla", STAGES_VANILLA, "Installing · Vanilla")

    @Slot()
    def startDeckBorne(self):
        # stages_deckborne(), not the constant: the mods row is resolved from what is in
        # payloads/mods/ at the moment the user clicks.
        self._start_install("deckborne", stages_deckborne(), "Installing · DeckBorne")

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
            self._proc.terminate()
            if not self._proc.waitForFinished(2000):
                self._proc.kill()
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
    def _start_install(self, profile, stages, headline):
        if self._mock:
            self._mock_begin(stages, headline)
        else:
            self._start_process([], {"DECKBORNE_PROFILE": profile}, stages, headline)

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
        proc.setProgram("bash")
        proc.setArguments([entry, *args])
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
