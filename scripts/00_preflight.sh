#!/usr/bin/env bash
# 00 — Preflight: sanity-check the environment before we touch anything.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"; load_env

step "Preflight checks"

# Tools the installer relies on. All ship with SteamOS.
require_cmd curl unzip sha256sum python3 awk find

# Warn (don't fail) if we don't look like a Steam Deck / SteamOS desktop.
if [ -r /etc/os-release ] && grep -qi 'steamos' /etc/os-release; then
  ok "SteamOS detected"
else
  warn "Not SteamOS — continuing, but this installer targets the Steam Deck (Desktop Mode)."
fi

# x86-64 only: the shadPS4 AppImage is x86-64.
arch="$(uname -m)"
[ "$arch" = "x86_64" ] || warn "Host arch is '$arch'; the shadPS4 AppImage is x86-64 and won't run here."

# The Steam tile step edits shortcuts.vdf, which is easiest from Desktop Mode.
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || warn "No display detected — run this from Desktop Mode so the Steam tile step works."

# Confirm the user dropped a game dump in game-ISO/. Identify it by PKG CONTENT, not
# filename, so any release/region names work (see discover_* in lib.sh).
base_pkg="$(discover_base_pkg || true)"
[ -n "$base_pkg" ] || die "No PS4 .pkg found under game-ISO/ (drop the base game dump there)."
title_id="$(pkg_title_id "$base_pkg")"
ok "Found base game: ${base_pkg#$DECKBORNE_ROOT/}  [${title_id:-unknown title id}]"
pkg_is_bloodborne "$base_pkg" \
  || warn "That .pkg does not identify as Bloodborne (content id: $(pkg_content_id "$base_pkg")). Continuing anyway."

update_pkg="$(discover_update_pkg "$base_pkg" || true)"
[ -n "$update_pkg" ] && ok "Found update: ${update_pkg#$DECKBORNE_ROOT/}" \
  || warn "No matching update .pkg found — base game will run un-patched."

# Free-space check: game extracts to ~30GB in \$HOME.
avail_kb="$(df -Pk "$HOME" | awk 'NR==2{print $4}')"
if [ "${avail_kb:-0}" -lt 35000000 ]; then
  warn "Less than ~33GB free in \$HOME — the extracted game needs ~30GB."
else
  ok "Sufficient free space in \$HOME"
fi

ok "Preflight complete"
