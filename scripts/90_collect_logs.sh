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
    echo "--- root nesting (first 12 lines) ---"
    head -n 12 "$lc" 2>/dev/null
    if [ -n "$tile_appid" ]; then
      echo "--- entry for appid $tile_appid ---"
      grep -n -A 8 "\"$tile_appid\"" "$lc" 2>/dev/null \
        || echo "(NO entry — Steam has no play record for this appid)"
    fi
    echo
  done
fi

# --- copy raw artifacts to the USB for full-fidelity review later -----------
snap="$DECKBORNE_ROOT/logs/state-$(date +%Y%m%d-%H%M%S 2>/dev/null || echo latest)"
mkdir -p "$snap" 2>/dev/null || true
[ -f "$SHADPS4_CONFIG_JSON" ] && cp -f "$SHADPS4_CONFIG_JSON" "$snap/" 2>/dev/null || true
[ -f "$CONFIG_TOML" ] && cp -f "$CONFIG_TOML" "$snap/legacy-config.toml" 2>/dev/null || true
for lf in "${logs[@]:-}"; do
  [ -n "$lf" ] && cp -f "$lf" "$snap/" 2>/dev/null || true
done
# localconfig.vdf named by Steam user id, so multi-account Decks stay unambiguous.
for lc in "${lcfgs[@]:-}"; do
  [ -n "$lc" ] || continue
  uid="$(basename "$(dirname "$(dirname "$lc")")")"
  cp -f "$lc" "$snap/localconfig-$uid.vdf" 2>/dev/null || true
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
