#!/usr/bin/env bash
# Shared helpers for DeckBorne scripts. Source this, don't execute it.

# Resolve repo root (parent of scripts/) regardless of where we're invoked from.
DECKBORNE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DECKBORNE_ROOT

# --- pretty logging ---------------------------------------------------------
_c() { printf '\033[%sm' "$1"; }   # color helper; no-op-safe on dumb terminals
log()   { printf '%s[DeckBorne]%s %s\n'  "$(_c '1;36')" "$(_c 0)" "$*"; }
ok()    { printf '%s  ✓%s %s\n'          "$(_c '1;32')" "$(_c 0)" "$*"; }
warn()  { printf '%s  ! %s%s\n'          "$(_c '1;33')" "$*" "$(_c 0)"; }
die()   { printf '%s  ✗ %s%s\n'          "$(_c '1;31')" "$*" "$(_c 0)" >&2; exit 1; }
step()  { printf '\n%s==>%s %s\n'        "$(_c '1;35')" "$(_c 0)" "$*"; }

# --- guards -----------------------------------------------------------------
require_cmd() {
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "required command not found: $c"
  done
}

# verify_sha256 <file> <expected-hex>
verify_sha256() {
  local file="$1" expected="$2" actual
  [ -f "$file" ] || die "checksum target missing: $file"
  actual="$(sha256sum "$file" | awk '{print $1}')"
  if [ "$actual" != "$expected" ]; then
    die "checksum mismatch for $(basename "$file")
       expected: $expected
       actual:   $actual"
  fi
  ok "checksum verified: $(basename "$file")"
}

# first match of a globstar pattern relative to repo root, or empty
find_one() {
  local pattern="$1" match
  shopt -s globstar nullglob
  # shellcheck disable=SC2206
  local matches=( $DECKBORNE_ROOT/$pattern )
  shopt -u globstar nullglob
  [ ${#matches[@]} -gt 0 ] && printf '%s\n' "${matches[0]}"
}

# --- machine-readable UI markers --------------------------------------------
# The UI (ui/backend.py) parses these; gated on DECKBORNE_UI so plain terminal
# runs never see them. Defined here (not just install.sh) so stage scripts can
# emit sub-progress during long operations (e.g. extraction).
ui_event() { [ "${DECKBORNE_UI:-0}" = 1 ] && printf '@@DBUI %s\n' "$*"; }

# --- PS4 .pkg identification (filename-independent) --------------------------
# A PS4 .pkg begins with magic 0x7F434E54 ("\x7FCNT") and carries a 36-byte ASCII
# content-id at offset 0x40, e.g. "EP9000-CUSA03173_00-BLOODBORNE0000EU". We read
# that to identify the game by CONTENT, not by whatever the user named the file —
# different release groups / regions name dumps differently.
_pkg_is_valid() {   # <pkg> -> 0 if it has the PS4 PKG magic
  [ -f "$1" ] || return 1
  [ "$(dd if="$1" bs=4 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')" = "7f434e54" ]
}
pkg_content_id() {  # <pkg> -> ASCII content-id (empty if unreadable)
  dd if="$1" bs=1 skip=64 count=36 2>/dev/null | tr -cd '[:print:]'
}
pkg_title_id() {    # <pkg> -> CUSAxxxxx from the content-id
  pkg_content_id "$1" | grep -oE 'CUSA[0-9]{5}' | head -1
}
pkg_is_bloodborne() { pkg_content_id "$1" | grep -qi 'bloodborne'; }

# discover_base_pkg -> path to the base game .pkg.
# Honours an explicit GAME_BASE_PKG_GLOB override if it matches; otherwise picks the
# LARGEST valid .pkg under game-ISO/ (a base game dwarfs any update/DLC — ~30GB vs MB).
discover_base_pkg() {
  local m; m="$(find_one "${GAME_BASE_PKG_GLOB:-__deckborne_none__}" 2>/dev/null || true)"
  [ -n "$m" ] && [ -f "$m" ] && { printf '%s\n' "$m"; return 0; }
  local best="" bestsize=-1 f sz
  shopt -s globstar nullglob
  for f in "$DECKBORNE_ROOT"/game-ISO/**/*.pkg; do
    _pkg_is_valid "$f" || continue
    sz="$(stat -c%s "$f" 2>/dev/null || echo 0)"
    [ "$sz" -gt "$bestsize" ] && { bestsize="$sz"; best="$f"; }
  done
  shopt -u globstar nullglob
  [ -n "$best" ] && printf '%s\n' "$best"
}

# discover_update_pkg <base-pkg> -> path to the patch .pkg (a patch shares the base's
# title-id). Honours GAME_UPDATE_PKG_GLOB override; else the largest OTHER valid .pkg
# with the same title-id as the base. Empty if there is none.
discover_update_pkg() {
  local base="$1" m; m="$(find_one "${GAME_UPDATE_PKG_GLOB:-__deckborne_none__}" 2>/dev/null || true)"
  [ -n "$m" ] && [ -f "$m" ] && { printf '%s\n' "$m"; return 0; }
  local tid; tid="$(pkg_title_id "$base")"; [ -n "$tid" ] || return 0
  local best="" bestsize=-1 f sz
  shopt -s globstar nullglob
  for f in "$DECKBORNE_ROOT"/game-ISO/**/*.pkg; do
    [ "$f" = "$base" ] && continue
    _pkg_is_valid "$f" || continue
    [ "$(pkg_title_id "$f")" = "$tid" ] || continue
    sz="$(stat -c%s "$f" 2>/dev/null || echo 0)"
    [ "$sz" -gt "$bestsize" ] && { bestsize="$sz"; best="$f"; }
  done
  shopt -u globstar nullglob
  [ -n "$best" ] && printf '%s\n' "$best"
}

# Load central config. Callers should `source lib.sh` then `load_env`.
load_env() {
  # shellcheck source=/dev/null
  source "$DECKBORNE_ROOT/config/deckborne.env"
}

# Print a system report — goes at the top of every run log so shared/archived
# logs carry the environment context (OS, arch, versions, free space) without
# having to ask for it. Requires load_env to have run.
deckborne_sysreport() {
  local os="unknown"
  [ -r /etc/os-release ] && os="$(. /etc/os-release; echo "${PRETTY_NAME:-${NAME:-unknown}}")"
  printf '===== DeckBorne run =====\n'
  printf 'time      : %s\n' "$(date 2>/dev/null || echo n/a)"
  printf 'user@host : %s @ %s\n' "$(id -un 2>/dev/null)" "$(uname -n 2>/dev/null)"
  printf 'system    : %s | %s | %s\n' "$os" "$(uname -sr 2>/dev/null)" "$(uname -m 2>/dev/null)"
  printf 'shadPS4   : %s (%s)\n' "$SHADPS4_VERSION" "$SHADPS4_APPIMAGE_NAME"
  printf 'game      : %s %s\n' "$GAME_NAME" "$GAME_TITLE_ID"
  printf 'usb repo  : %s\n' "$DECKBORNE_ROOT"
  printf 'home free : %s (%s)\n' \
    "$(df -h "$HOME" 2>/dev/null | awk 'NR==2{print $4}')" "$HOME"
  printf 'steam     : %s\n' \
    "$(command -v steam >/dev/null 2>&1 && echo 'on PATH' || echo 'NOT on PATH')"
  printf 'emu ready : %s\n' \
    "$([ -x "$APP_DIR/$SHADPS4_APPIMAGE_NAME" ] && echo yes || echo no)"
  printf '=========================\n'
}

# --- Steam lifecycle --------------------------------------------------------
# Steam rewrites shortcuts.vdf from memory when it exits, so it must be fully
# closed while we add/remove a tile. steam_stop closes it gracefully and sets
# STEAM_WAS_RUNNING (0/1); steam_start relaunches it. Both are no-ops when Steam
# isn't running/installed. Used by both 50_steam_shortcut.sh and the uninstaller.
STEAM_WAS_RUNNING=0
steam_stop() {
  STEAM_WAS_RUNNING=0
  pgrep -x steam >/dev/null 2>&1 || return 0
  command -v steam >/dev/null 2>&1 || \
    die "Steam is running but 'steam' isn't on PATH — close it manually and retry."
  log "Shutting Steam down cleanly (it rewrites shortcuts.vdf on exit)…"
  steam -shutdown >/dev/null 2>&1 || true
  local i
  for i in $(seq 1 60); do pgrep -x steam >/dev/null 2>&1 || break; sleep 1; done
  if pgrep -x steam >/dev/null 2>&1; then
    warn "Steam didn't exit within 60s — sending a graceful TERM…"
    pkill -TERM -x steam 2>/dev/null || true; sleep 3
  fi
  pgrep -x steam >/dev/null 2>&1 && die "Could not close Steam. Close it manually and retry."
  ok "Steam closed"
  STEAM_WAS_RUNNING=1
}
# -silent starts Steam minimised to the tray rather than raising the client window
# over whatever you're doing — the installer restarts Steam as a side effect of
# writing shortcuts.vdf, so it shouldn't steal focus on the way out. Steam still
# runs normally: it loads the new tile and can launch it (the Recent Games warm-up
# in stage 50 drives it through steam://rungameid while it's silent).
# ${VAR-default}, not ${VAR:-default}: only substitute when UNSET, so an explicit
# STEAM_START_FLAGS="" really means "no flags" instead of silently re-adding them.
STEAM_START_FLAGS="${STEAM_START_FLAGS--silent}"
# Steam must not be launched as a plain child of this script.
#
# xdg-desktop-portal identifies the app making a request by its systemd scope
# (cgroup), NOT by its binary. A child of the installer stays inside the
# terminal's own scope, so Steam gets seen as the terminal: on the Deck that
# surfaced as Plasma prompting "choose which screen to share with konsolerun"
# after every install. Steam asks the portal for desktop capture (Remote Play) at
# startup and keeps a restore token for it — localconfig.vdf's
# streaming_v2/DesktopCaptureRestoreToken — but the token is tied to Steam's real
# identity, so under the terminal's identity it can't restore and you get prompted.
#
# Launching into our own app-steam-<pid>.scope matches the convention desktop
# environments use for app units (app-<desktop-id>-<random>.scope), which gives
# Steam its identity back so the token restores silently.
steam_start() {
  # $1 (optional) overrides the launch flags. Default: $STEAM_START_FLAGS (-silent),
  # right for the warm-up's transient internal restart. Pass "" for a VISIBLE window.
  #
  # -silent was chosen so Steam comes back quietly, but on the Deck's KDE desktop it
  # starts Steam to a tray icon that never surfaces — so -silent reads as "Steam never
  # came back", the symptom chased across several rounds. Confirmed on-device 2026-07-17
  # (uninstall log, flags=''): dropping -silent opens the window; scope and display are
  # identical either way. So USER-FACING restarts (after an install/uninstall finishes)
  # pass "" to be visible; only the internal warm-up restart stays -silent.
  local flags="${1-$STEAM_START_FLAGS}"
  command -v steam >/dev/null 2>&1 || return 0
  log "Restarting Steam in the background…"
  # shellcheck disable=SC2086 — deliberate word-splitting: flags/setenv lists
  if steam_can_scope; then
    # Launch Steam into its own app-steam-<pid>.scope. Two properties, both confirmed
    # on-device 2026-07-17 (this is the fix the whole Steam-restart saga converged on):
    #   * PORTAL IDENTITY: xdg-desktop-portal recognizes a `.scope` as an app-unit and
    #     reads app-id `steam` from app-steam-<pid>.scope (Steam fact 7), so the
    #     screen-share restore token matches and the portal stays quiet. A `.service` is
    #     NOT parsed that way — it falls back to the raw PID and prompts every run. (An
    #     earlier attempt used a --user service; it survived but re-opened the portal
    #     prompt. The scope keeps both.)
    #   * SURVIVAL: a plain `systemd-run --user --scope` runs in the CALLER's process tree
    #     and dies when the script exits. setsid gives the scope a NEW session so the
    #     script's exit can't reap it — the detachment a service would get from the manager.
    # --setenv forwards the graphical vars so the window actually shows.
    setsid systemd-run --user --scope --quiet --unit="app-steam-$$" \
      ${WAYLAND_DISPLAY:+--setenv=WAYLAND_DISPLAY} \
      ${DISPLAY:+--setenv=DISPLAY} \
      ${XDG_RUNTIME_DIR:+--setenv=XDG_RUNTIME_DIR} \
      ${DBUS_SESSION_BUS_ADDRESS:+--setenv=DBUS_SESSION_BUS_ADDRESS} \
      -- steam $flags >/dev/null 2>&1 </dev/null &
    disown 2>/dev/null || true
    log "  (own app-steam scope — portal-recognized + detached via setsid)"
    return 0
  fi
  # No usable user bus: fall back. setsid puts Steam in its OWN session so the script's
  # exit (and any SIGHUP) can't take it down.
  setsid steam $flags >/dev/null 2>&1 </dev/null &
  disown 2>/dev/null || true
}

# The user-facing restart: bring Steam back VISIBLE and confirm it actually came up
# before returning. Use this at the end of an install/uninstall — never a bare
# steam_start there.
#
# Detachment (surviving the script exit) is now steam_start's job — it launches Steam as
# a --user service. This wait is for CONFIRMATION: steam_start returns instantly, so we
# wait for `steam` to appear, settle, then check both `steam` and `steamwebhelper` (the
# real client, not the bootstrap launcher) so the log reports the truth instead of a
# fire-and-forget guess. If Steam still dies after this reports success, the kill is
# ACTIVE (SteamOS session management / a stray steam -shutdown), not a lifetime issue —
# the service launch would already have ruled out cgroup/scope teardown.
steam_restart_visible() {
  steam_start ""            # "" = no -silent → a real window (see steam_start)
  local i steam_up=0
  for i in $(seq 1 30); do
    pgrep -x steam >/dev/null 2>&1 && { steam_up=1; break; }
    sleep 1
  done
  [ "$steam_up" = 1 ] && sleep "${DECKBORNE_STEAM_SETTLE:-10}"
  if [ "$steam_up" = 1 ] && pgrep -x steam >/dev/null 2>&1 && pgrep -x steamwebhelper >/dev/null 2>&1; then
    ok "Steam is back up on your desktop."
    return 0
  fi
  # Didn't come up — leave the facts in the log rather than a bare failure.
  warn "Steam may not have come back up on its own — open it from the desktop if so."
  local sp; sp="$(pgrep -x steam 2>/dev/null | head -1 || true)"
  [ -n "$sp" ] && warn "  diag: steam pid=$sp cgroup=$(grep -o 'app\.slice/.*' "/proc/$sp/cgroup" 2>/dev/null | head -1 || echo '?')"
  warn "  diag: steam=[$(pgrep -x steam 2>/dev/null | tr '\n' ' ')] webhelper=[$(pgrep -x steamwebhelper 2>/dev/null | tr '\n' ' ')]"
  warn "  diag: app-steam scopes=[$(systemctl --user list-units 'app-steam-*' --no-legend --all 2>/dev/null | awk 'NF{print $1"("$3")"}' | tr '\n' ' ')]"
  return 1
}

# Probe rather than assume: systemd-run can exist but fail (no user bus in a
# headless/ssh session), and since the real launch is backgrounded we'd never see
# it fail — Steam would just silently never start.
steam_can_scope() {
  [ "${STEAM_USE_SCOPE:-1}" = 1 ] || return 1
  command -v systemd-run >/dev/null 2>&1 || return 1
  systemd-run --user --scope --quiet -- true >/dev/null 2>&1
}
