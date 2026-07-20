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

# Confirm the user dropped a game dump in game-pkg/. Identify it by PKG CONTENT, not
# filename, so any release/region names work (see discover_* in lib.sh).
base_pkg="$(discover_base_pkg || true)"
[ -n "$base_pkg" ] || die "No PS4 .pkg found under game-pkg/ (drop the base game dump there)."
title_id="$(pkg_title_id "$base_pkg")"
ok "Found base game: ${base_pkg#$DECKBORNE_ROOT/}  [${title_id:-unknown title id}]"
pkg_is_bloodborne "$base_pkg" \
  || warn "That .pkg does not identify as Bloodborne (content id: $(pkg_content_id "$base_pkg")). Continuing anyway."

update_pkg="$(discover_update_pkg "$base_pkg" || true)"
[ -n "$update_pkg" ] && ok "Found update: ${update_pkg#$DECKBORNE_ROOT/}" \
  || warn "No matching update .pkg found — base game will run un-patched."

# Network: REQUIRED. DeckBorne never bundles the patch XML — stage 35 always pulls it
# from the shadPS4 project's repo so users get the current set, and stage 10 downloads
# the emulator too. We check HERE rather than letting stage 35 discover it, because
# stage 35 runs AFTER the ~30GB extract: failing there means the user waits out a long
# install to be told it was pointless. Stage 35 itself stays non-fatal by design (a
# network drop mid-install must not cost someone their extract) — this check is what
# makes "internet required" true without that destructive failure mode.
if [ "${DECKBORNE_SKIP_NET_CHECK:-0}" = 1 ]; then
  warn "Skipping the connectivity check (DECKBORNE_SKIP_NET_CHECK=1)."
  warn "  If the network is down you will get NO game patches."
elif curl -fsS --max-time 15 --range 0-0 -o /dev/null "$PATCHES_URL" 2>/dev/null; then
  ok "Network reachable — patches will be downloaded during install"
else
  die "No connection to the patch server ($PATCHES_URL).
  DeckBorne needs internet: it downloads the emulator and the shadPS4 game patches
  at install time rather than shipping stale copies.
  Connect your system to the internet and run this again.
  To install anyway WITHOUT patches: DECKBORNE_SKIP_NET_CHECK=1 ./install.sh"
fi

# Free-space check: game extracts to ~30GB in \$HOME.
avail_kb="$(df -Pk "$HOME" | awk 'NR==2{print $4}')"
if [ "${avail_kb:-0}" -lt 35000000 ]; then
  warn "Less than ~33GB free in \$HOME — the extracted game needs ~30GB."
else
  ok "Sufficient free space in \$HOME"
fi

ok "Preflight complete"
