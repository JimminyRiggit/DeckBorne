#!/usr/bin/env bash
# 90 — Collect logs & state for troubleshooting. Run any time (e.g. after a crash
# in Game Mode):  bash install.sh collect
#
# Prints config + shadPS4's own logs to stdout (so they land in the run log you
# can paste back), AND copies the raw files into logs/state-<timestamp>/ on the
# USB so nothing is lost. Purely read-only; never modifies the install.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"; load_env

step "Collecting logs & state"

CONFIG_TOML="$CONFIG_DIR/config.toml"
snap="$DECKBORNE_ROOT/logs/state-$(date +%Y%m%d-%H%M%S 2>/dev/null || echo latest)"
mkdir -p "$snap" 2>/dev/null || true

have() { command -v "$1" >/dev/null 2>&1; }
_sha() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }
_pin_check() {
  local actual="$1" pinned="$2"
  [ -z "$actual" ] && { echo "(missing)"; return; }
  [ "$actual" = "$pinned" ] && echo "matches pin" || echo "!! DOES NOT MATCH PIN"
}

sysinfo() {
  echo "----- system & environment (no Steam account data) -----"
  [ -r /etc/os-release ] && (. /etc/os-release; printf 'os          : %s (BUILD_ID=%s VARIANT=%s)\n' \
    "${PRETTY_NAME:-?}" "${BUILD_ID:-?}" "${VARIANT_ID:-?}")
  printf 'kernel      : %s\n' "$(uname -sr 2>/dev/null)"
  printf 'arch        : %s\n' "$(uname -m 2>/dev/null)"
  local cpu
  cpu="$(awk -F: '/model name/{print $2; exit}' /proc/cpuinfo 2>/dev/null | sed 's/^ *//')"
  [ -n "$cpu" ] || cpu="$(lscpu 2>/dev/null | awk -F: '/Model name/{print $2; exit}' | sed 's/^ *//')"
  printf 'cpu         : %s\n' "${cpu:-unknown}"
  printf 'ram         : %s\n' "$(awk '/MemTotal/{printf "%.1f GB", $2/1048576}' /proc/meminfo 2>/dev/null)"
  printf 'session     : %s / %s\n' "${XDG_SESSION_TYPE:-?}" "${XDG_CURRENT_DESKTOP:-?}"
  printf 'free $HOME  : %s\n' "$(df -h "$HOME" 2>/dev/null | awk 'NR==2{print $4}')"
  printf 'free USB    : %s (%s)\n' \
    "$(df -h "$DECKBORNE_ROOT" 2>/dev/null | awk 'NR==2{print $4}')" \
    "$(df -T "$DECKBORNE_ROOT" 2>/dev/null | awk 'NR==2{print $2}')"
  echo
  echo "-- graphics (present-mode + pipeline-cache questions live here) --"
  lspci 2>/dev/null | grep -iE 'vga|3d|display' || echo "(lspci unavailable)"
  if have vulkaninfo; then
    vulkaninfo --summary 2>/dev/null | grep -iE 'deviceName|driverName|driverInfo|apiVersion' | head -8 \
      || echo "(vulkaninfo produced nothing)"
  else
    echo "(vulkaninfo not installed)"
  fi
  printf 'gamescope   : %s\n' \
    "$(have gamescope && { gamescope --version 2>&1 | head -1; } || echo 'not installed')"
  echo
  echo "-- runtime bits DeckBorne depends on --"
  printf 'python3     : %s\n' "$(python3 -V 2>&1)"
  printf '/dev/fuse   : %s\n' "$([ -e /dev/fuse ] && echo present || echo MISSING)"
  for t in fusermount fusermount3 systemd-inhibit kde-inhibit kdialog zenity curl unzip sha256sum; do
    printf '%-12s: %s\n' "$t" "$(command -v $t 2>/dev/null || echo '-')"
  done
  printf 'python-dbus : %s\n' "$(python3 -c 'import dbus; print("available")' 2>/dev/null || echo 'not available')"
  echo
  echo "-- active inhibitors (stay-awake) --"
  systemd-inhibit --list --no-pager 2>/dev/null | head -15 || echo "(unavailable)"
  echo
  echo "-- emulator & extractor integrity --"
  local emu="$APP_DIR/$SHADPS4_APPIMAGE_NAME" ext="$APP_DIR/tools/$PKG_EXTRACTOR_APPIMAGE" a
  a="$(_sha "$emu")"; printf 'emulator    : %s\n              sha=%s %s\n' \
    "$([ -f "$emu" ] && stat -c '%s bytes' "$emu" || echo 'NOT INSTALLED')" "${a:-n/a}" "$(_pin_check "$a" "$SHADPS4_APPIMAGE_SHA256")"
  a="$(_sha "$ext")"; printf 'extractor   : %s\n              sha=%s %s\n' \
    "$([ -f "$ext" ] && stat -c '%s bytes' "$ext" || echo 'NOT INSTALLED')" "${a:-n/a}" "$(_pin_check "$a" "$PKG_EXTRACTOR_SHA256")"
  echo
  echo "-- patches installed --"
  if [ -d "$PATCHES_DIR" ]; then find "$PATCHES_DIR" -type f -printf '%10s  %P\n' 2>/dev/null | head -20
  else echo "(no patches dir at $PATCHES_DIR)"; fi
  echo
  echo "-- mods staged on this media --"
  find "$DECKBORNE_ROOT/payloads/mods" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null || echo "(none)"
  echo
  echo "-- kernel messages: storage / fuse (media corruption + AppImage mount) --"
  { journalctl -k --no-pager -n 400 2>/dev/null || dmesg 2>/dev/null; } \
    | grep -iE 'exfat|vfat|usb-storage|I/O error|fuse' | tail -20 || echo "(none, or not readable)"
  echo
  echo "-- DeckBorne UI launch log (tail) --"
  if [ -f "$DECKBORNE_ROOT/logs/ui-launch.log" ]; then
    tail -25 "$DECKBORNE_ROOT/logs/ui-launch.log"
  else
    echo "(no ui-launch.log — the UI has not been started from this media)"
  fi
  echo
}

sysinfo | tee "$snap/sysinfo.txt" 2>/dev/null || sysinfo
echo

# The REAL config. ~/.config/shadps4/config.toml is a dead path nothing reads — collecting
# only that is what let a completely inert config layer look healthy for weeks.
echo "----- config.json ($SHADPS4_CONFIG_JSON) -----"
if [ -f "$SHADPS4_CONFIG_JSON" ]; then
  cat "$SHADPS4_CONFIG_JSON"
  python3 -c "import json,sys; json.load(open(sys.argv[1])); print('(valid JSON)')" \
    "$SHADPS4_CONFIG_JSON" 2>/dev/null || echo "(!! NOT VALID JSON — shadPS4 will fall back to defaults)"
else
  echo "(not found — shadPS4 writes it on first exit; stage 30 also creates it)"
fi

echo
echo "----- legacy config.toml ($CONFIG_TOML) — DEAD PATH, informational only -----"
if [ -f "$CONFIG_TOML" ]; then cat "$CONFIG_TOML"; else echo "(not present)"; fi
echo

echo "----- storage / install location -----"
echo "storage root : $DECKBORNE_STORAGE_ROOT $(storage_is_external && echo '(EXTERNAL device)' || echo '(internal)')"
echo "games dir    : $GAMES_DIR"
echo "remembered   : $(cat "$DECKBORNE_STORAGE_FILE" 2>/dev/null || echo '(none recorded)')"
python3 "$DECKBORNE_ROOT/scripts/detect_storage.py" --human 2>/dev/null || echo "(detection failed)"
echo

echo "----- installed game -----"
if [ -f "$APP_DIR/.boot_target" ]; then
  bt="$(cat "$APP_DIR/.boot_target")"
  echo "boot target: $bt"
  ls -la "$(dirname "$bt")" 2>/dev/null | head -n 20
else
  echo "(game not installed yet — run stage 20)"
fi
echo

echo "----- shadPS4 log files -----"
# shadPS4's log location has moved across versions/builds; check the known spots.
#
# ⚠ DO NOT narrow this back to '*.log'. shadPS4 names its log **shad_log.txt**, so an
# `-iname '*.log'` filter matched NOTHING and every collect cheerfully reported "no log
# files found" — which is why the emulator's own runtime log (the only place that shows
# the booted game version and whether patches were applied) was never once captured.
# Match .txt as well, and print what was searched when nothing turns up.
search_dirs=(
  "$CONFIG_DIR"
  "$HOME/.local/share/shadps4"
  "$HOME/.local/share/shadPS4"
  "$APP_DIR/user"
)
mapfile -t logs < <(find "${search_dirs[@]}" \
  -maxdepth 3 -type f \( -iname '*.log' -o -iname '*log*.txt' \) 2>/dev/null | sort -u)

if [ "${#logs[@]}" -eq 0 ]; then
  echo "(no shadPS4 log files found. searched, for *.log and *log*.txt:)"
  printf '   %s\n' "${search_dirs[@]}"
else
  for lf in "${logs[@]}"; do
    echo ">>> $lf  ($(wc -l < "$lf" 2>/dev/null) lines, $(stat -c %s "$lf" 2>/dev/null) bytes) <<<"
    # HEAD FIRST. Everything diagnostic — emulator version, game serial, app version,
    # and whether the patch directory was read — is printed at BOOT. The tail is
    # thousands of near-identical shader-compile lines. Echoing only the tail (which is
    # what this did) looked like a full log while containing nothing that identifies the
    # run. Keep both: head for what loaded, tail for how it ended.
    echo "--- first 80 lines (boot: version, serial, patches) ---"
    head -n 80 "$lf" 2>/dev/null
    echo "--- lines mentioning patch/serial/version anywhere in the file ---"
    grep -niE "patch|serial|game ver|app ver|title id|CUSA" "$lf" 2>/dev/null | head -n 40 \
      || echo "(none)"
    echo "--- last 60 lines (how it ended) ---"
    tail -n 60 "$lf" 2>/dev/null
    echo
  done
fi

echo "----- Steam shortcuts (shortcuts.vdf) -----"
# Steam REWRITES this file whenever it exits, so what's on disk is Steam's shape,
# not the one add_shortcut.py wrote — key casing and Exe quoting can differ. Dump
# every field verbatim: that's the ground truth for tile add/remove matching.
mapfile -t scuts < <(realpath -e \
  "$HOME/.steam/steam/userdata"/*/config/shortcuts.vdf \
  "$HOME/.local/share/Steam/userdata"/*/config/shortcuts.vdf \
  "$HOME/.var/app/com.valvesoftware.Steam/data/Steam/userdata"/*/config/shortcuts.vdf \
  2>/dev/null | sort -u)

if [ "${#scuts[@]}" -eq 0 ]; then
  echo "(no shortcuts.vdf found — no non-Steam games added yet?)"
else
  for sc in "${scuts[@]}"; do
    echo ">>> $sc  ($(stat -c %s "$sc" 2>/dev/null) bytes) <<<"
    DECKBORNE_SC="$sc" python3 -c '
import os, sys
sys.path.insert(0, os.path.join(os.environ["DECKBORNE_ROOT"], "steam"))
import add_shortcut
buf = open(os.environ["DECKBORNE_SC"], "rb").read()
try:
    sc = add_shortcut.parse(buf).get("shortcuts", {})
except Exception as e:
    print(f"  (parse failed: {type(e).__name__}: {e})"); raise SystemExit
print(f"  {len(sc)} shortcut(s)")
for k, v in sc.items():
    if not isinstance(v, dict):
        continue
    print(f"  [{k}]")
    for fk, fv in v.items():
        print(f"      {fk!r:18} = {fv!r}")' 2>&1 | head -80
    echo
  done
fi

echo "----- Steam play records (localconfig.vdf) -----"
# Steam logs real play sessions to localconfig.vdf — Software/Valve/Steam/apps/
# <appid>/LastPlayed — NOT to shortcuts.vdf's LastPlayTime. That's what puts a
# game on the Recent Games shelf, so this is where to look when the tile is
# missing from Recent. Read-only: we print the entry and copy the file, nothing else.
tile_appid="$(APPIMAGE="$APP_DIR/$SHADPS4_APPIMAGE_NAME" TILE="$STEAM_TILE_NAME" python3 -c '
import os, sys
sys.path.insert(0, os.path.join(os.environ["DECKBORNE_ROOT"], "steam"))
import add_shortcut
print(add_shortcut.grid_appid(os.environ["APPIMAGE"], os.environ["TILE"]))' 2>/dev/null)"
echo "tile appid: ${tile_appid:-(could not compute)}"

# Same roots add_shortcut.py writes to; realpath -s|sort -u collapses the
# .steam/steam -> .local/share/Steam symlink so we don't dump the file twice.
mapfile -t lcfgs < <(realpath -e \
  "$HOME/.steam/steam/userdata"/*/config/localconfig.vdf \
  "$HOME/.local/share/Steam/userdata"/*/config/localconfig.vdf \
  "$HOME/.var/app/com.valvesoftware.Steam/data/Steam/userdata"/*/config/localconfig.vdf \
  2>/dev/null | sort -u)

if [ "${#lcfgs[@]}" -eq 0 ]; then
  echo "(no localconfig.vdf found — has Steam run and signed in?)"
else
  for lc in "${lcfgs[@]}"; do
    echo ">>> $lc  ($(stat -c %s "$lc" 2>/dev/null) bytes) <<<"
    echo "--- structure (summary only: raw lines are NOT printed, this file holds auth tickets) ---"
    DECKBORNE_LC="$lc" python3 -c '
import os, sys
sys.path.insert(0, os.path.join(os.environ["DECKBORNE_ROOT"], "steam"))
import add_shortcut as a
text = open(os.environ["DECKBORNE_LC"], encoding="utf-8", errors="surrogateescape").read()
node = a._find_path(text, a.LOCALCONFIG_APPS)
if node is None:
    print("  Software/Valve/Steam/apps NOT FOUND — unexpected layout")
    raise SystemExit
kids = list(a._children(text, node["body_start"], node["body_end"]))
size = node["end"] - node["key_start"]
print(f"  Software/Valve/Steam/apps found: {len(kids)} app entries, {size} bytes")
print(f"  (whole file is {len(text)} bytes; only the apps block is snapshotted)")' 2>/dev/null \
      || echo "  (could not parse — layout unexpected)"
    if [ -n "$tile_appid" ]; then
      echo "--- entry for appid $tile_appid ---"
      grep -n -A 8 "\"$tile_appid\"" "$lc" 2>/dev/null \
        || echo "(NO entry — Steam has no play record for this appid)"
    fi
    echo
  done
fi

# --- copy raw artifacts to the USB for full-fidelity review later -----------
[ -f "$SHADPS4_CONFIG_JSON" ] && cp -f "$SHADPS4_CONFIG_JSON" "$snap/" 2>/dev/null || true
[ -f "$CONFIG_TOML" ] && cp -f "$CONFIG_TOML" "$snap/legacy-config.toml" 2>/dev/null || true
for lf in "${logs[@]:-}"; do
  [ -n "$lf" ] && cp -f "$lf" "$snap/" 2>/dev/null || true
done
# localconfig.vdf holds the user's Steam settings AND LIVE AUTH TICKETS. Only the
# Software/Valve/Steam/apps block was ever needed, so only that is extracted — the whole
# file is never written to the USB, because the point of "collect logs" is to produce
# something safe to hand to a stranger. If extraction fails, copy NOTHING.
for lc in "${lcfgs[@]:-}"; do
  [ -n "$lc" ] || continue
  uid="$(basename "$(dirname "$(dirname "$lc")")")"
  if DECKBORNE_LC="$lc" DECKBORNE_OUT="$snap/localconfig-apps-$uid.vdf" python3 -c '
import os, sys
sys.path.insert(0, os.path.join(os.environ["DECKBORNE_ROOT"], "steam"))
import add_shortcut as a
src = os.environ["DECKBORNE_LC"]
text = open(src, encoding="utf-8", errors="surrogateescape").read()
node = a._find_path(text, a.LOCALCONFIG_APPS)
if node is None:
    sys.exit("apps block not found")
with open(os.environ["DECKBORNE_OUT"], "w", encoding="utf-8", errors="surrogateescape") as fh:
    fh.write("// DeckBorne: Software/Valve/Steam/apps extracted from localconfig.vdf.\n")
    fh.write("// The rest of that file (Steam settings and LIVE AUTH TICKETS) is deliberately\n")
    fh.write("// NOT copied. Safe to share.\n")
    fh.write(text[node["key_start"]:node["end"]] + "\n")
' 2>/dev/null; then
    ok "  apps block extracted from $(basename "$(dirname "$(dirname "$lc")")")/localconfig.vdf"
  else
    warn "  could not extract the apps block from $lc"
    warn "    nothing copied — the full file is never snapshotted (it carries auth tickets)"
  fi
done
for sc in "${scuts[@]:-}"; do
  [ -n "$sc" ] || continue
  uid="$(basename "$(dirname "$(dirname "$sc")")")"
  cp -f "$sc" "$snap/shortcuts-$uid.vdf" 2>/dev/null || true
done

# Force the copies onto the stick. THIS IS NOT OPTIONAL — same failure as the run log
# before finalize_log() got its sync: the directory entries flush but the DATA does not,
# so a snapshot arrives as a set of 0-byte files. Observed 2026-07-18: an entire collect
# (config.toml, shad_log.txt, both vdfs) landed 0-byte while the echoed copies in the run
# log were fine. Tell-tale: 0-byte files in state-*/ next to a populated run log.
sync 2>/dev/null || true

ok "Raw copies saved to: $snap"
for f in "$snap"/*; do
  [ -e "$f" ] || continue
  sz="$(stat -c %s "$f" 2>/dev/null || echo 0)"
  if [ "$sz" -gt 0 ]; then
    printf '     %-32s %s bytes\n' "$(basename "$f")" "$sz"
  else
    warn "   $(basename "$f") is 0 BYTES — copy did not land"
  fi
done
ok "To share everything at once, paste the run log: logs/latest.log"
