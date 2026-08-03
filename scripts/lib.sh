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
die()   { ui_error "$*"; printf '%s  ✗ %s%s\n' "$(_c '1;31')" "$*" "$(_c 0)" >&2; exit 1; }
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
# ⚠ The trailing `return 0` is load-bearing. Without it this is `[ test ] && printf`,
# which returns 1 whenever DECKBORNE_UI != 1 — and every stage runs under `set -e`, so
# a plain terminal run exits SILENTLY at the first marker, mid-stage, reporting nothing.
ui_event() { [ "${DECKBORNE_UI:-0}" = 1 ] && printf '@@DBUI %s\n' "$*"; return 0; }

ui_error() {
  [ "${DECKBORNE_UI:-0}" = 1 ] || return 0
  local out="" line first=1
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line//\\/\\\\}"
    if [ "$first" = 1 ]; then out="$line"; first=0; else out="$out\\n$line"; fi
  done <<< "$*"
  printf '@@DBUI ERROR %s\n' "$out"
}

KEEP_AWAKE_FLAG=""
KEEP_AWAKE_METHODS=""

# Suspend and screen-blanking are SEPARATE mechanisms on KDE. logind's idle/sleep
# inhibitor stops auto-suspend but does NOT stop PowerDevil dimming and switching the
# panel off, which is what the Deck was still doing mid-install. That needs a
# ScreenSaver/PowerManagement inhibition, and those are released the moment the calling
# D-Bus connection drops — so every method below HOLDS a process open for the run.
_keep_awake_watch='while [ -e "$1" ] && kill -0 "$2" 2>/dev/null; do sleep 2; done'

_keep_awake_sleep() {
  command -v systemd-inhibit >/dev/null 2>&1 || return 1
  systemd-inhibit --what=sleep:idle:handle-lid-switch --who="DeckBorne" \
    --why="DeckBorne install in progress" --mode=block \
    bash -c "$_keep_awake_watch" _ "$KEEP_AWAKE_FLAG" "$$" >/dev/null 2>&1 &
  local i held=0
  for i in 1 2 3 4 5 6; do
    held="$(systemd-inhibit --list --no-pager 2>/dev/null | grep -c 'DeckBorne')"
    [ "${held:-0}" -gt 0 ] && break
    sleep 0.25
  done
  [ "${held:-0}" -gt 0 ] || return 1
  KEEP_AWAKE_METHODS="$KEEP_AWAKE_METHODS systemd-inhibit(suspend)"
}

_keep_awake_screen_dbus() {
  python3 -c 'import dbus' >/dev/null 2>&1 || return 1
  python3 - "$KEEP_AWAKE_FLAG" "$$" >/dev/null 2>&1 <<'PY' &
import os, sys, time, dbus

flag, guard = sys.argv[1], int(sys.argv[2])
targets = [
    ("org.freedesktop.ScreenSaver", "/org/freedesktop/ScreenSaver",
     "org.freedesktop.ScreenSaver", "screensaver"),
    ("org.freedesktop.PowerManagement.Inhibit", "/org/freedesktop/PowerManagement/Inhibit",
     "org.freedesktop.PowerManagement.Inhibit", "powermanagement"),
]
bus = dbus.SessionBus()
held = []
for name, path, iface, label in targets:
    try:
        obj = bus.get_object(name, path)
        cookie = obj.Inhibit("DeckBorne", "DeckBorne install in progress",
                             dbus_interface=iface)
        held.append((obj, iface, cookie, label))
    except Exception:
        pass
if not held:
    sys.exit(1)
with open(flag + ".screen", "w") as fh:
    fh.write("+".join(h[3] for h in held))
while os.path.exists(flag):
    try:
        os.kill(guard, 0)
    except OSError:
        break
    time.sleep(2)
for obj, iface, cookie, _ in held:
    try:
        obj.UnInhibit(cookie, dbus_interface=iface)
    except Exception:
        pass
PY
  local i granted=""
  for i in 1 2 3 4 5 6 7 8; do
    [ -s "$KEEP_AWAKE_FLAG.screen" ] && { granted="$(cat "$KEEP_AWAKE_FLAG.screen")"; break; }
    sleep 0.5
  done
  [ -n "$granted" ] || return 1
  KEEP_AWAKE_METHODS="$KEEP_AWAKE_METHODS dbus-$granted(screen)"
}

_keep_awake_screen_kde() {
  command -v kde-inhibit >/dev/null 2>&1 || return 1
  kde-inhibit --power-management --screenSaver \
    bash -c "$_keep_awake_watch" _ "$KEEP_AWAKE_FLAG" "$$" >/dev/null 2>&1 &
  local pid=$!
  sleep 0.5
  kill -0 "$pid" 2>/dev/null || return 1
  KEEP_AWAKE_METHODS="$KEEP_AWAKE_METHODS kde-inhibit(screen,unverified)"
}

keep_awake_begin() {
  [ "${DECKBORNE_KEEP_AWAKE:-1}" = 1 ] || { warn "Stay-awake disabled (DECKBORNE_KEEP_AWAKE=0)"; return 0; }
  [ -z "$KEEP_AWAKE_FLAG" ] || return 0
  KEEP_AWAKE_FLAG="$(mktemp -t deckborne-awake.XXXXXX 2>/dev/null)" || { KEEP_AWAKE_FLAG=""; return 0; }
  KEEP_AWAKE_METHODS=""

  _keep_awake_sleep || warn "Could not inhibit suspend — the Deck may sleep mid-install."
  _keep_awake_screen_dbus || _keep_awake_screen_kde \
    || warn "Could not inhibit screen blanking — the screen may switch off mid-install."

  if [ -n "$KEEP_AWAKE_METHODS" ]; then
    ok "Staying awake for this run:$KEEP_AWAKE_METHODS"
  else
    warn "No stay-awake mechanism available — the Deck may sleep mid-install."
    warn "  Workaround: System Settings > Power Management, set 'Screen Energy Saving'"
    warn "  and automatic suspend to Never for the duration of the install."
  fi
}

keep_awake_end() {
  [ -n "${KEEP_AWAKE_FLAG:-}" ] || return 0
  rm -f "$KEEP_AWAKE_FLAG" "$KEEP_AWAKE_FLAG.screen" 2>/dev/null || true
  KEEP_AWAKE_FLAG=""
  KEEP_AWAKE_METHODS=""
}

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
# LARGEST valid .pkg under game-pkg/ (a base game dwarfs any update/DLC — ~30GB vs MB).
discover_base_pkg() {
  local m; m="$(find_one "${GAME_BASE_PKG_GLOB:-__deckborne_none__}" 2>/dev/null || true)"
  [ -n "$m" ] && [ -f "$m" ] && { printf '%s\n' "$m"; return 0; }
  local best="" bestsize=-1 f sz
  shopt -s globstar nullglob
  for f in "$DECKBORNE_ROOT"/game-pkg/**/*.pkg; do
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
  for f in "$DECKBORNE_ROOT"/game-pkg/**/*.pkg; do
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
  DECKBORNE_STATE_DIR="${DECKBORNE_STATE_DIR:-${HOME}/.local/share/DeckBorne}"
  DECKBORNE_SETTINGS_FILE="${DECKBORNE_SETTINGS_FILE:-${DECKBORNE_STATE_DIR}/settings.env}"
  if [ -r "$DECKBORNE_SETTINGS_FILE" ]; then
    # shellcheck source=/dev/null
    source "$DECKBORNE_SETTINGS_FILE"
  fi
  # shellcheck source=/dev/null
  source "$DECKBORNE_ROOT/config/deckborne.env"
}

persist_storage_root() {
  mkdir -p "$DECKBORNE_STATE_DIR" 2>/dev/null || return 0
  printf '%s\n' "$DECKBORNE_STORAGE_ROOT" > "$DECKBORNE_STORAGE_FILE" 2>/dev/null || {
    warn "could not record the install location — a later 'install.sh 50' or uninstall"
    warn "  will fall back to \$HOME. Pass DECKBORNE_STORAGE_ROOT explicitly if so."
    return 0
  }
  sync "$DECKBORNE_STORAGE_FILE" 2>/dev/null || sync 2>/dev/null || true
}

forget_storage_root() { rm -f "$DECKBORNE_STORAGE_FILE" 2>/dev/null || true; }

storage_is_external() { [ "$DECKBORNE_STORAGE_ROOT" != "$HOME" ]; }

storage_check() {
  python3 "$DECKBORNE_ROOT/scripts/detect_storage.py" --check "$DECKBORNE_STORAGE_ROOT"
}

# Sets INSTALLED_TITLE_ID from an EXISTING install, without reading any .pkg. Empty when
# nothing is installed. Deliberately does not require the game file to exist: the marker
# still names the title when the game lives on a device that is currently elsewhere, which
# is exactly the relocation case.
INSTALLED_TITLE_ID=""
installed_title_id() {
  INSTALLED_TITLE_ID=""
  local f="$APP_DIR/.boot_target" t d
  if [ -f "$f" ]; then
    t="$(cat "$f" 2>/dev/null || true)"
    if [ -n "$t" ]; then
      d="$(basename "$(dirname "$t")" 2>/dev/null || true)"
      case "$d" in
        *-UPDATE) d="${d%-UPDATE}" ;;
      esac
      [ -n "$d" ] && [ "$d" != "/" ] && [ "$d" != "." ] && INSTALLED_TITLE_ID="$d"
    fi
  fi
  [ -z "$INSTALLED_TITLE_ID" ] || return 0
  local dir
  for dir in "$GAMES_DIR"/*/; do
    [ -f "${dir}eboot.bin" ] || continue
    d="$(basename "$dir")"
    case "$d" in
      *-UPDATE|*.pre-mods) continue ;;
    esac
    INSTALLED_TITLE_ID="$d"
    return 0
  done
  return 0
}

# Sets BOOT_TARGET, or dies. Must NOT return the path on stdout — see CLAUDE.md.
BOOT_TARGET=""
require_boot_target() {
  local f="$APP_DIR/.boot_target" t
  [ -f "$f" ] || die "game not installed yet — run 20_install_game.sh first"
  t="$(cat "$f" 2>/dev/null || true)"
  [ -n "$t" ] || die "boot target marker is empty — re-run 20_install_game.sh"
  if [ ! -f "$t" ]; then
    if storage_is_external && [ ! -d "$DECKBORNE_STORAGE_ROOT" ]; then
      die "the game is installed on $DECKBORNE_STORAGE_ROOT, which is not mounted.
  Plug that device back in and run this again."
    fi
    die "the installed game is missing: $t
  Re-run the install (or 20_install_game.sh) to extract it again."
  fi
  BOOT_TARGET="$t"
}

# Print a system report — goes at the top of every run log so shared/archived
# logs carry the environment context (OS, arch, versions, free space) without
# having to ask for it. Requires load_env to have run.
deckborne_sysreport() {
  local os="unknown"
  [ -r /etc/os-release ] && os="$(. /etc/os-release; echo "${PRETTY_NAME:-${NAME:-unknown}}")"
  printf '===== DeckBorne run =====\n'
  printf 'deckborne : v%s\n' "$DECKBORNE_VERSION"
  printf 'time      : %s\n' "$(date 2>/dev/null || echo n/a)"
  printf 'user@host : %s @ %s\n' "$(id -un 2>/dev/null)" "$(uname -n 2>/dev/null)"
  printf 'system    : %s | %s | %s\n' "$os" "$(uname -sr 2>/dev/null)" "$(uname -m 2>/dev/null)"
  printf 'shadPS4   : %s (%s)\n' "$SHADPS4_VERSION" "$SHADPS4_APPIMAGE_NAME"
  printf 'game      : %s %s\n' "$GAME_NAME" "$GAME_TITLE_ID"
  printf 'profile   : %s%s\n' "${DECKBORNE_PROFILE:-deckborne}" \
    "$([ "${DECKBORNE_PROFILE:-deckborne}" = deckborne ] && printf '  target: %s' "${DECKBORNE_TARGET:-deck30}")"
  printf 'usb repo  : %s\n' "$DECKBORNE_ROOT"
  printf 'home free : %s (%s)\n' \
    "$(df -h "$HOME" 2>/dev/null | awk 'NR==2{print $4}')" "$HOME"
  printf 'install to: %s%s\n' "$DECKBORNE_STORAGE_ROOT" \
    "$(storage_is_external && echo '  [external device]' || echo '  [internal]')"
  printf 'games dir : %s (%s free, %s)\n' "$GAMES_DIR" \
    "$(df -h "$DECKBORNE_STORAGE_ROOT" 2>/dev/null | awk 'NR==2{print $4}')" \
    "$(df -PT "$DECKBORNE_STORAGE_ROOT" 2>/dev/null | awk 'NR==2{print $2}')"
  printf 'steam     : %s\n' \
    "$(command -v steam >/dev/null 2>&1 && echo 'on PATH' || echo 'NOT on PATH')"
  printf 'emu ready : %s\n' \
    "$([ -x "$APP_DIR/$SHADPS4_APPIMAGE_NAME" ] && echo yes || echo no)"
  printf 'workshop  : gpu=%s fps-counter=%s hdr=%s present=%s shader-cache=%s%s\n' \
    "$VULKAN_GPU_ID" "$DECKBORNE_FPS_COUNTER" "$DECKBORNE_HDR" \
    "$DECKBORNE_PRESENT_MODE" "$DECKBORNE_SHADER_CACHE" \
    "$([ -r "$DECKBORNE_SETTINGS_FILE" ] && printf '  [%s]' "$DECKBORNE_SETTINGS_FILE")"
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
  # Reason goes to a FILE, not $(…): steam -shutdown can leave a child holding stdout,
  # and a command substitution would then block until that child exits.
  local i errlog
  errlog="$(mktemp 2>/dev/null || echo "/tmp/deckborne-steam-stop.$$.err")"
  steam -shutdown >"$errlog" 2>&1 </dev/null || true
  for i in $(seq 1 60); do pgrep -x steam >/dev/null 2>&1 || break; sleep 1; done
  if pgrep -x steam >/dev/null 2>&1; then
    warn "Steam didn't exit within 60s — sending a graceful TERM…"
    if [ -s "$errlog" ]; then
      warn "  steam -shutdown said: $(tr '\n' ' ' < "$errlog")"
    fi
    # POLL after the TERM — Steam needs to flush configs and tear down steamwebhelper,
    # which routinely takes longer than a fixed sleep. See CLAUDE.md.
    pkill -TERM -x steam 2>/dev/null || true
    for i in $(seq 1 "${DECKBORNE_STEAM_TERM_WAIT:-30}"); do
      pgrep -x steam >/dev/null 2>&1 || break; sleep 1
    done
  fi
  rm -f "$errlog" 2>/dev/null || true
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
STEAM_START_UNIT=""
STEAM_START_ERRLOG=""
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
    #   * UNIQUENESS: unit name must differ per call — see CLAUDE.md. Keep the shape
    #     `app-steam-<ONE segment>` or the portal app-id stops being "steam".
    STEAM_START_UNIT="app-steam-$(date +%s%N 2>/dev/null || echo "$$$RANDOM")"
    STEAM_START_ERRLOG="$(mktemp 2>/dev/null || echo "/tmp/deckborne-steam-start.$$.err")"
    setsid systemd-run --user --scope --quiet --unit="$STEAM_START_UNIT" \
      ${WAYLAND_DISPLAY:+--setenv=WAYLAND_DISPLAY} \
      ${DISPLAY:+--setenv=DISPLAY} \
      ${XDG_RUNTIME_DIR:+--setenv=XDG_RUNTIME_DIR} \
      ${DBUS_SESSION_BUS_ADDRESS:+--setenv=DBUS_SESSION_BUS_ADDRESS} \
      -- steam $flags >/dev/null 2>"$STEAM_START_ERRLOG" </dev/null &
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
  warn "  diag: requested unit=${STEAM_START_UNIT:-none}"
  if [ -n "${STEAM_START_ERRLOG:-}" ] && [ -s "$STEAM_START_ERRLOG" ]; then
    warn "  diag: systemd-run said: $(tr '\n' ' ' < "$STEAM_START_ERRLOG")"
  fi
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
