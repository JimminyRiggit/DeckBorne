#!/usr/bin/env bash
# 30 — Apply shadPS4 emulator settings for Bloodborne.
#
# Writes ~/.local/share/shadPS4/config.json (v0.16's real config — see the long note in
# config/deckborne.env). MERGES: shadPS4 keeps every one of its settings in this file,
# so anything we don't set is left exactly as the user had it.
#
# HISTORY — this stage did NOTHING for weeks. It wrote ~/.config/shadps4/config.toml:
# wrong directory (shadPS4 uses XDG_DATA_HOME, never XDG_CONFIG_HOME), wrong case
# (shadPS4 vs shadps4), wrong file (config.json since 0.16), and wrong key names
# (snake_case members, not the old camelCase TOML keys). Every setting the emulator
# reported was its built-in default. It hid because the default vblank_frequency is 60 —
# exactly the value we were trying to set — so the one key anyone spot-checked always
# looked correct. The giveaway was `isDevKitMode = true` in our file versus
# `isDevKit: false` in the emulator's own boot log.
#
# NOT SET, deliberately: dev_kit_mode. The old config forced it true because a guide said
# so, but it never actually applied and the game has run fine without it. Don't reinstate
# it without knowing what it does for Bloodborne.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"; load_env

PATCHER="$DECKBORNE_ROOT/config/patch_config_json.py"

step "Applying shadPS4 settings"

# Vblank is PROFILE-DEPENDENT: it must match the frame-rate patch stage 35 enables.
# See the pairing rule in config/deckborne.env (30/60 FPS++ -> 60, 90 FPS++ -> 90+).
# ⚠ EXPLICIT CASES, and an unknown profile DIES. This used to be `*) deckborne values`,
# which meant a typo — or a new profile name someone forgot to wire up here — silently
# got deckborne's settings and reported success. That is this project's signature bug
# (a cheerful log line over a no-op), so the catch-all is gone.
profile="${DECKBORNE_PROFILE:-deckborne}"
present="$PRESENT_MODE"
pcache="$PIPELINE_CACHE"
# Empty means "do not write this key at all" — see the tuned-profile block below. deckborne
# leaves all three empty, which is what keeps its config surface exactly what it always was.
extra_dmem=""
fsr=""
log_sync=""
case "$profile" in
  vanilla)   vblank="$VBLANK_HZ_VANILLA"
             present="$PRESENT_MODE_VANILLA"
             pcache="$PIPELINE_CACHE"
             extra_dmem="$EXTRA_DMEM_MB_VANILLA"
             fsr="$FSR_VANILLA"
             log_sync="$LOG_SYNC_VANILLA" ;;
  deckborne) vblank="$VBLANK_HZ_DECKBORNE" ;;
  chocolate) vblank="$VBLANK_HZ_CHOCOLATE"
             present="$PRESENT_MODE_CHOCOLATE"
             pcache="$PIPELINE_CACHE_CHOCOLATE"
             extra_dmem="$EXTRA_DMEM_MB_CHOCOLATE"
             fsr="$FSR_CHOCOLATE"
             log_sync="$LOG_SYNC_CHOCOLATE" ;;
  *) die "unknown DECKBORNE_PROFILE '$profile' — expected vanilla|deckborne|chocolate" ;;
esac
ok "Profile '$profile' → vblank ${vblank}Hz, present ${present}, pipeline cache ${pcache}"

# shadPS4 rewrites config.json on exit, so an edit made while it runs is lost.
if pgrep -f "$SHADPS4_APPIMAGE_NAME" >/dev/null 2>&1; then
  warn "shadPS4 appears to be RUNNING — it rewrites config.json on exit, so these"
  warn "  settings may be overwritten. Close the emulator and re-run this stage."
fi

settings=(
  "GPU.vblank_frequency=$vblank"
  "GPU.window_width=$WINDOW_W"
  "GPU.window_height=$WINDOW_H"
  "GPU.internal_screen_width=$INTERNAL_W"
  "GPU.internal_screen_height=$INTERNAL_H"
  "GPU.full_screen=true"
  "GPU.full_screen_mode=$FULLSCREEN_MODE"
  "GPU.present_mode=$present"
  "Vulkan.pipeline_cache_enabled=$pcache"
  "General.show_fps_counter=$DECKBORNE_SHOW_FPS"
)

# Keys written for the TUNED profiles only (vanilla + chocolate). Appended rather than
# added to the list above so DECKBORNE keeps writing exactly the key set it always has —
# it is frozen, and this must not quietly change its config surface.
# ⚠ WAS chocolate-only until 2026-07-19. Vanilla joined when chocolate's proven config was
# promoted into it; the whole clean on-device session ran with these three keys set, so
# omitting them for vanilla would ship a config that was never the one tested.
# Key names verified against v.0.16.0 emulator_settings.h; see config/deckborne.env.
if [ -n "$extra_dmem" ]; then
  settings+=(
    "General.extra_dmem_in_mbytes=$extra_dmem"   # int; shadPS4 default 0
    "GPU.fsr_enabled=$fsr"
    "Log.sync=$log_sync"   # async == sync:false. Log.type is _WIN32-only.
  )
  ok "Tuned keys → extra_dmem ${extra_dmem}MB, fsr ${fsr}, log sync ${log_sync}"
fi

# Not a warn on the vanilla path: vanilla is the shipping default now, and these values are
# the ones it was actually tested on. Only chocolate is genuinely expected to misbehave.
if [ "$profile" = chocolate ]; then
  warn "CHOCOLATE is EXPERIMENTAL and currently carries '30 FPS++', the CONFIRMED cause of"
  warn "  the vertex-explosion artifacting. Without the user-supplied Nexus fix mod in"
  warn "  payloads/mods/, this profile is EXPECTED to render incorrectly — that is the test."
  warn "  extra_dmem ${extra_dmem}MB is a 0 -> ${extra_dmem} change (first suspect if it crashes)."
fi

python3 "$PATCHER" "$SHADPS4_CONFIG_JSON" "${settings[@]}"
ok "Settings written to $SHADPS4_CONFIG_JSON"

# READ IT BACK. Not a grep — a parse plus an exact type comparison. A grep for the right
# line passes on a file the emulator rejects, which is precisely how the TOML version
# fooled us. Types matter as much as values here: shadPS4 throws on a type mismatch and
# every section after the bad one silently reverts to defaults.
if python3 "$PATCHER" --check "$SHADPS4_CONFIG_JSON" "${settings[@]}"; then
  ok "config.json validated (all keys read back with correct types)"
else
  warn "config.json did NOT validate — these settings will not apply. See above."
fi

if [ "$PIPELINE_CACHE" = "true" ]; then
  ok "Vulkan pipeline cache ON — first launch still compiles (~550 pipelines/shaders);"
  ok "  later launches reuse them. Judge smoothness on the SECOND run, not the first."
fi
