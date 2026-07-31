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
target="${DECKBORNE_TARGET:-deck30}"
present="$PRESENT_MODE"
pcache="$PIPELINE_CACHE"
# Empty means "do not write this key at all" — see the tuned-profile block below. As of the
# 2026-07-19 promotion ALL THREE profiles set them; the empty default is kept because it is
# the safe fallback for any profile added later, which must opt IN to these keys.
extra_dmem=""
fsr=""
log_sync=""
# ⚠ NOT "" like the opt-in keys above. These two are written by EVERY profile and target, at
# the emulator's own defaults, because config.json is MERGED: a key one target writes and
# another omits does not revert on a switch, it persists. Leaving gpu_id unwritten let a
# desktop VULKAN_GPU_ID_DESKTOP=1 survive a switch back to a Deck, where index 1 does not
# exist — and an out-of-range gpu_id is a FATAL assert, not a fallback.
gpu_id="$VULKAN_GPU_ID"
hdr="$HDR_ALLOWED"
# PER-PROFILE as of 2026-07-23 (was one global for all three). OFF for the two shipping
# profiles, ON for chocolate — see the reasoning in config/deckborne.env. The initialiser
# is the fallback for a profile that forgets to set it; the `*)` below still dies, so it
# only ever applies to a future profile someone wires in above without touching this.
show_fps="$DECKBORNE_SHOW_FPS"
win_w="$WINDOW_W"
win_h="$WINDOW_H"
int_w="$INTERNAL_W"
int_h="$INTERNAL_H"
case "$profile" in
  vanilla)   vblank="$VBLANK_HZ_VANILLA"
             present="$PRESENT_MODE_VANILLA"
             pcache="$PIPELINE_CACHE"
             extra_dmem="$EXTRA_DMEM_MB_VANILLA"
             fsr="$FSR_VANILLA"
             show_fps="$SHOW_FPS_VANILLA"
             hdr="$HDR_VANILLA"
             log_sync="$LOG_SYNC_VANILLA" ;;
  # PROMOTED FROM CHOCOLATE 2026-07-19 — deckborne now writes the same tuned key set as
  # vanilla and chocolate. It used to write none of them (no present override, no dmem/fsr/
  # log keys), so this is a genuine change to its config surface, made deliberately: the
  # promotion is only valid if deckborne runs the config that was actually tested.
  deckborne) vblank="$VBLANK_HZ_DECKBORNE"
             present="$PRESENT_MODE_DECKBORNE"
             pcache="$PIPELINE_CACHE"
             extra_dmem="$EXTRA_DMEM_MB_DECKBORNE"
             fsr="$FSR_DECKBORNE"
             show_fps="$SHOW_FPS_DECKBORNE"
             hdr="$HDR_DECKBORNE"
             log_sync="$LOG_SYNC_DECKBORNE"
             case "$target" in
               deck30|deck60) ;;
               desktop) win_w="$WINDOW_W_DESKTOP"
                        win_h="$WINDOW_H_DESKTOP"
                        int_w="$INTERNAL_W_DESKTOP"
                        int_h="$INTERNAL_H_DESKTOP"
                        extra_dmem="$EXTRA_DMEM_MB_DESKTOP"
                        fsr="$FSR_DESKTOP"
                        gpu_id="$VULKAN_GPU_ID_DESKTOP" ;;
               *) die "unknown DECKBORNE_TARGET '$target' — expected deck30|deck60|desktop" ;;
             esac ;;
  chocolate) vblank="$VBLANK_HZ_CHOCOLATE"
             present="$PRESENT_MODE_CHOCOLATE"
             pcache="$PIPELINE_CACHE_CHOCOLATE"
             extra_dmem="$EXTRA_DMEM_MB_CHOCOLATE"
             fsr="$FSR_CHOCOLATE"
             show_fps="$SHOW_FPS_CHOCOLATE"
             hdr="$HDR_CHOCOLATE"
             log_sync="$LOG_SYNC_CHOCOLATE" ;;
  *) die "unknown DECKBORNE_PROFILE '$profile' — expected vanilla|deckborne|chocolate" ;;
esac
case "$DECKBORNE_FPS_COUNTER" in
  auto) ;;
  on)   show_fps="true" ;;
  off)  show_fps="false" ;;
  *) die "unknown DECKBORNE_FPS_COUNTER '$DECKBORNE_FPS_COUNTER' — expected auto|on|off" ;;
esac
case "$DECKBORNE_HDR" in
  auto) ;;
  on)   hdr="true" ;;
  off)  hdr="false" ;;
  *) die "unknown DECKBORNE_HDR '$DECKBORNE_HDR' — expected auto|on|off" ;;
esac
case "$DECKBORNE_PRESENT_MODE" in
  auto) ;;
  fifo)      present="Fifo" ;;
  mailbox)   present="Mailbox" ;;
  immediate) present="Immediate" ;;
  *) die "unknown DECKBORNE_PRESENT_MODE '$DECKBORNE_PRESENT_MODE' — expected auto|fifo|mailbox|immediate" ;;
esac
case "$DECKBORNE_SHADER_CACHE" in
  auto) ;;
  on)   pcache="true" ;;
  off)  pcache="false" ;;
  *) die "unknown DECKBORNE_SHADER_CACHE '$DECKBORNE_SHADER_CACHE' — expected auto|on|off" ;;
esac

target_note=""
if [ "$profile" = deckborne ]; then target_note=" (target '$target')"; fi
ok "Profile '$profile'${target_note} → vblank ${vblank}Hz, present ${present}, pipeline cache ${pcache}, FPS counter ${show_fps}"
ok "Resolution → window ${win_w}x${win_h}, internal ${int_w}x${int_h}"
if [ "$LOG_APPEND" = "true" ]; then
  ok "Emulator log → appending, so shad_log.txt keeps every launch (not just the last)."
else
  warn "Emulator log → TRUNCATED each launch. The install's own warm-up will overwrite the"
  warn "  evidence of a previous profile before you can collect it. Set LOG_APPEND=true."
fi

# shadPS4 rewrites config.json on exit, so an edit made while it runs is lost.
if pgrep -f "$SHADPS4_APPIMAGE_NAME" >/dev/null 2>&1; then
  warn "shadPS4 appears to be RUNNING — it rewrites config.json on exit, so these"
  warn "  settings may be overwritten. Close the emulator and re-run this stage."
fi

settings=(
  "GPU.vblank_frequency=$vblank"
  "GPU.window_width=$win_w"
  "GPU.window_height=$win_h"
  "GPU.internal_screen_width=$int_w"
  "GPU.internal_screen_height=$int_h"
  "GPU.full_screen=true"
  "GPU.full_screen_mode=$FULLSCREEN_MODE"
  "GPU.present_mode=$present"
  "Vulkan.pipeline_cache_enabled=$pcache"
  "General.show_fps_counter=$show_fps"
  "Log.append=$LOG_APPEND"
)

# Keys written by any profile that opts in (all three do, as of 2026-07-19). Kept as a
# separate appended block rather than folded into the list above so that a profile added
# later starts from the minimal key set and has to ASK for these.
# ⚠ HISTORY, so the churn reads as deliberate: chocolate-only when introduced → vanilla
# joined on its promotion → deckborne joined on the 30 FPS++ promotion. Each time the
# reason was the same: the profile must run the config that was actually tested on-device.
# Key names verified against v.0.16.0 emulator_settings.h; see config/deckborne.env.
if [ -n "$extra_dmem" ]; then
  settings+=(
    "General.extra_dmem_in_mbytes=$extra_dmem"   # int; shadPS4 default 0
    "GPU.fsr_enabled=$fsr"
    "Log.sync=$log_sync"   # async == sync:false. Log.type is _WIN32-only.
  )
  ok "Tuned keys → extra_dmem ${extra_dmem}MB, fsr ${fsr}, log sync ${log_sync}"
fi

if [ -n "$hdr" ]; then
  settings+=("GPU.hdr_allowed=$hdr")
  if [ "$hdr" = "true" ]; then
    ok "HDR → permitted. shadPS4 still requires the display to advertise Rec.2020 PQ, and"
    ok "  stock Bloodborne never requests HDR — this is here for mods that add it."
  else
    ok "HDR → not permitted"
  fi
fi

if [ -n "$gpu_id" ]; then
  python3 "$DECKBORNE_ROOT/scripts/detect_gpu.py" --human 2>/dev/null | while IFS= read -r line; do
    ok "$line"
  done
  if [ "$gpu_id" != "-1" ]; then
    if python3 "$DECKBORNE_ROOT/scripts/detect_gpu.py" --validate "$gpu_id" >/dev/null 2>&1
    then gpu_rc=0; else gpu_rc=$?; fi
    case "$gpu_rc" in
      1) warn "GPU device index $gpu_id DOES NOT EXIST on this machine — falling back to auto."
         warn "  An out-of-range Vulkan.gpu_id is a fatal assert in shadPS4 at startup, not a"
         warn "  fallback, so writing it would leave the game unable to launch at all."
         gpu_id="-1" ;;
      2) warn "GPU device index $gpu_id could NOT be verified — vulkaninfo is not installed."
         warn "  If that index does not exist, shadPS4 will abort at startup. Install"
         warn "  vulkan-tools, or set the graphics device back to Auto in the Workshop." ;;
    esac
  fi
  settings+=("Vulkan.gpu_id=$gpu_id")
  if [ "$gpu_id" = "-1" ]; then
    ok "GPU selection → auto. shadPS4 ranks devices itself (Vulkan 1.3, then discrete, then VRAM)."
  else
    warn "GPU selection → FORCED to device index $gpu_id, bypassing shadPS4's own ranking."
    warn "  Confirmed present in the device list above."
  fi
fi

# Not a warn on the vanilla path: vanilla is the shipping default now, and these values are
# the ones it was actually tested on. Only chocolate is genuinely expected to misbehave.
if [ "$profile" = deckborne ] && [ "$target" != deck30 ]; then
  case "$target" in
    deck60)  warn "Target 'deck60' is BETA. 60 FPS++ is PROVEN to render correctly with the"
             warn "  vertex-explosion mod applied, but a standard Deck cannot hold 60 — the"
             warn "  frame rate will not be even. Reinstall on 30 FPS if it plays badly." ;;
    desktop) warn "Target 'desktop' is for hardware that is NOT a Steam Deck, and has never run"
             warn "  on any device. It renders at ${win_w}x${win_h} via 'Optimal 1080p'."
             warn "  A docked Deck is still a Deck and will not hold 60 here." ;;
  esac
fi

if [ "$DECKBORNE_PRESENT_MODE" = immediate ]; then
  warn "Present mode FORCED to Immediate. Every Deck run so far logged 'Requested present mode"
  warn "  Immediate is not supported, falling back to Fifo' — the driver does not advertise"
  warn "  IMMEDIATE for this surface. Check shad_log.txt before believing it took effect."
fi
if [ "$DECKBORNE_SHADER_CACHE" = on ]; then
  warn "Shader cache FORCED ON. It did NOT work in four consecutive on-device tests on shadPS4"
  warn "  $SHADPS4_VERSION, and it has no size limit and no eviction — it writes hundreds of"
  warn "  files per launch and never reads them back. Only a 'Preloaded N pipelines' line in"
  warn "  shad_log.txt means it worked; the absence of a warning does NOT."
fi

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

if [ "$pcache" = "true" ]; then
  ok "Vulkan pipeline cache ON — first launch still compiles (~550 pipelines/shaders);"
  ok "  later launches reuse them. Judge smoothness on the SECOND run, not the first."
fi
