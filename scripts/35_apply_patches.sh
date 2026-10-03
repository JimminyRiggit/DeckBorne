#!/usr/bin/env bash
# 35 — Apply shadPS4 game patches for the active profile.
#
# Patches are NOT mods. shadPS4 reads XML patch files at boot and applies memory
# patches to the running game. Frame-rate and QOL tweaks for Bloodborne live here;
# file-overlay mods live in stage 40 and are unrelated.
#
# WHAT THIS DOES:
#   fetch Bloodborne.xml  ->  ~/.local/share/shadPS4/patches/shadPS4/
#   generate files.json   ->  same dir  (maps xml -> title-ids; the emulator needs it)
#   set isEnabled="true"  ->  only on this profile's patches, "false" on all others
#   verify by re-reading everything back
#
# TRAPS THIS GUARDS (all verified against the emulator's source, 2026-07-18):
#   * ⚠⚠ files.json is LOAD-BEARING and on v0.16.0 a MISSING one is FATAL, not skipped.
#     memory_patcher iterates every subdirectory of patches/ and does, with no existence
#     check and no try/catch:
#         std::ifstream json_file{repo.path() / "files.json"};
#         nlohmann::json available_patches = nlohmann::json::parse(json_file);
#     A failed ifstream parses as empty input, nlohmann throws, nothing catches it, and
#     the emulator TERMINATES before the game starts. So an EMPTY patches subdirectory
#     makes the game unlaunchable — "no patches" is harmless, an empty dir is not.
#     Hence: this stage never creates dest_dir before it is ready to write a valid
#     files.json, every failure path calls prune_unusable_patch_dir, and files.json is
#     written BEFORE the xml so an interrupted write leaves a valid index pointing at a
#     missing file (which the emulator skips safely) rather than a dir with no index.
#     ⚠ Upstream main has since added both guards — do NOT re-read the current source and
#     conclude this is over-defensive. It is v0.16.0, the shipped AppImage, that crashes.
#     Found 2026-09-25: an upstream patch RENAME made every profile fail the name check,
#     which left exactly this empty dir on a user's Deck. 13 launches, 13 terminates.
#   * The shipped XML has NO isEnabled attribute at all — the Qt launcher adds it when
#     a user ticks a box. So we INSERT the attribute; a find/replace assuming it exists
#     would match nothing and silently apply no patches.
#   * Path is ~/.local/share/shadPS4/patches, NOT ~/.config/shadps4 (that's config.toml).
#   * PORTABLE MODE: if a `user/` directory exists in the emulator's CWD, it reads
#     ./user/patches instead and never looks at the XDG path. We warn if that's set up.
#   * AppVer on every Bloodborne patch is 01.09. A different game version means the
#     patch won't apply. We report the expected version rather than assume.
#
# Non-fatal by design: this runs AFTER the ~30GB extract, so a dead network must not
# cost the user their install. It warns loudly and exits 0; re-run standalone with
#     bash scripts/35_apply_patches.sh
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"; load_env

step "Applying game patches"

# ⚠ EXPLICIT CASES, unknown profile DIES — see the same change in 30_apply_config.sh.
# The old `*)` catch-all meant `DECKBORNE_PROFILE=choclate` (typo) would silently install
# deckborne's single patch and print a success line.
profile="${DECKBORNE_PROFILE:-deckborne}"
target="${DECKBORNE_TARGET:-deck30}"
case "$profile" in
  vanilla)   want="$PATCHES_VANILLA"   ;;
  deckborne)
    case "$target" in
      deck30)  want="$PATCHES_DECKBORNE" ;;
      deck60)  want="$PATCHES_DECKBORNE_DECK60" ;;
      desktop) want="$PATCHES_DECKBORNE_DESKTOP" ;;
      *) die "unknown DECKBORNE_TARGET '$target' — expected deck30|deck60|desktop" ;;
    esac
    ok "Target '$target'" ;;
  chocolate) want="$PATCHES_CHOCOLATE" ;;
  *) die "unknown DECKBORNE_PROFILE '$profile' — expected vanilla|deckborne|chocolate" ;;
esac

if [ -z "${want// /}" ]; then
  ok "Profile '$profile' requests no patches — nothing to do."
  exit 0
fi
log "Profile '$profile' wants: $want"

# Title-id: prefer the one actually installed (derived from the PKG header at extract
# time) over the config fallback, so a different region's dump still matches.
title_id="$GAME_TITLE_ID"
boot_target_file="$APP_DIR/.boot_target"
if [ -f "$boot_target_file" ]; then
  derived="$(basename "$(dirname "$(cat "$boot_target_file")")")"
  [ -n "$derived" ] && title_id="$derived"
fi
ok "Title id: $title_id"

# Portable-mode warning: costs nothing to check, and it silently redirects where the
# emulator reads patches from.
if [ -d "$APP_DIR/user" ]; then
  warn "$APP_DIR/user exists — if the emulator runs with that as its CWD it uses"
  warn "  portable mode (./user/patches) and will IGNORE $PATCHES_DIR."
fi

dest_dir="$PATCHES_DIR/$PATCHES_SOURCE_DIR"
dest_xml="$dest_dir/$PATCHES_XML_NAME"
files_json="$dest_dir/files.json"

prune_unusable_patch_dir() {
  [ -d "$dest_dir" ] || return 0
  if [ -s "$files_json" ] \
     && python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$files_json" 2>/dev/null; then
    return 0
  fi
  rm -f "$files_json" "$files_json.tmp" "$dest_xml.tmp"
  if rmdir "$dest_dir" 2>/dev/null; then
    return 0
  fi
  local parked
  parked="$PATCHES_DIR-disabled/$PATCHES_SOURCE_DIR-$(date +%s)"
  mkdir -p "$(dirname "$parked")"
  if mv "$dest_dir" "$parked" 2>/dev/null; then
    warn "Moved an unusable patch dir aside (no valid files.json): $parked"
    warn "  shadPS4 v0.16.0 crashes at boot on a patches subdir without one."
  else
    warn "$dest_dir has no valid files.json and could not be removed."
    warn "  shadPS4 will CRASH AT BOOT until you delete it:  rm -rf '$dest_dir'"
  fi
}
prune_unusable_patch_dir

disable_stale_patches() {
  [ -s "$dest_xml" ] || return 0
  if PATCH_DEST="$dest_xml" python3 2>/dev/null <<'PY'
import os
import xml.etree.ElementTree as ET
dest = os.environ["PATCH_DEST"]
tree = ET.parse(dest)
for m in tree.getroot().findall(".//Metadata"):
    m.set("isEnabled", "false")
tree.write(dest + ".tmp", encoding="utf-8", xml_declaration=True)
os.replace(dest + ".tmp", dest)
PY
  then
    warn "Switched off the patches left from a previous install, so none apply."
  else
    rm -f "$dest_xml.tmp"
    warn "Could not switch off the previous install's patches in $dest_xml —"
    warn "  the LAST profile's patches will still apply. Delete that file to clear them."
  fi
}

tmp_xml="$(mktemp)"
trap 'rm -f "$tmp_xml"' EXIT

log "Fetching $PATCHES_URL"
# -sS: no progress meter (this is a ~200KB file; the meter is pure log noise) but
# still print the reason on failure.
if ! curl -fsSL --max-time 60 -o "$tmp_xml" "$PATCHES_URL" || [ ! -s "$tmp_xml" ]; then
  if [ -s "$dest_xml" ] && [ -s "$files_json" ]; then
    warn "Could not download the patch file (no network?)."
    warn "  Using the copy already on this device to apply profile '$profile'."
    cp "$dest_xml" "$tmp_xml"
  else
    warn "Could not download the patch file (no network?). PATCHES NOT APPLIED."
    warn "The game is fully playable — it just runs unpatched."
    warn "Re-run later with:  bash scripts/35_apply_patches.sh"
    prune_unusable_patch_dir
    exit 0
  fi
fi

# The real work in python: parsing XML, matching patch names, inserting attributes and
# emitting files.json are all things bash would do badly and silently.
if ! PATCH_SRC="$tmp_xml" PATCH_DEST="$dest_xml" PATCH_JSON="$files_json" \
     PATCH_XMLNAME="$PATCHES_XML_NAME" PATCH_TITLEID="$title_id" PATCH_WANT="$want" \
     python3 <<'PY'
import json, os, sys
import xml.etree.ElementTree as ET

src, dest = os.environ["PATCH_SRC"], os.environ["PATCH_DEST"]
json_path, xml_name = os.environ["PATCH_JSON"], os.environ["PATCH_XMLNAME"]
title_id = os.environ["PATCH_TITLEID"]
want = [p.strip() for p in os.environ["PATCH_WANT"].split(";") if p.strip()]

try:
    tree = ET.parse(src)
except ET.ParseError as e:
    print(f"  ! downloaded file is not valid XML: {e}", file=sys.stderr)
    sys.exit(2)
root = tree.getroot()

metas = root.findall(".//Metadata")
if not metas:
    print("  ! no <Metadata> elements — upstream format changed?", file=sys.stderr)
    sys.exit(2)

# Title-ids are <ID> children of the Metadata blocks; collect every one in the file.
ids = sorted({(e.text or "").strip() for e in root.findall(".//ID") if (e.text or "").strip()})
if title_id not in ids:
    print(f"  ! this patch file does not cover {title_id}", file=sys.stderr)
    print(f"  ! it covers: {', '.join(ids)}", file=sys.stderr)
    sys.exit(3)

by_name = {}
for m in metas:
    n = m.get("Name")
    if n:
        by_name.setdefault(n, m)

missing = [w for w in want if w not in by_name]
if missing:
    print(f"  ! patch name(s) not found upstream: {', '.join(missing)}", file=sys.stderr)
    print("  ! available names in this file:", file=sys.stderr)
    for n in sorted(by_name):
        print(f"  !   {n}", file=sys.stderr)
    sys.exit(4)

# Set every patch explicitly. The shipped file omits isEnabled entirely, and we do NOT
# want to depend on what the emulator assumes for a missing attribute — an unspecified
# default could silently enable things the profile never asked for.
for name, m in by_name.items():
    m.set("isEnabled", "true" if name in want else "false")

appvers = sorted({by_name[w].get("AppVer", "?") for w in want})
os.makedirs(os.path.dirname(dest), exist_ok=True)

tmp_json = json_path + ".tmp"
with open(tmp_json, "w", encoding="utf-8") as fh:
    json.dump({xml_name: ids}, fh, indent=2)
os.replace(tmp_json, json_path)

tmp_out = dest + ".tmp"
tree.write(tmp_out, encoding="utf-8", xml_declaration=True)
os.replace(tmp_out, dest)

print(f"ENABLED={len(want)} TOTAL={len(by_name)} APPVER={','.join(appvers)}")
PY
then
  warn "Patch file could not be applied (see the error above). PATCHES NOT APPLIED."
  warn "The game is fully playable — it just runs unpatched."
  disable_stale_patches
  prune_unusable_patch_dir
  exit 0
fi

# ---- verify: read back what we actually wrote --------------------------------
# The whole point of this stage is not repeating the project's favourite bug, where a
# success line is printed over a no-op. Nothing above is trusted.
if ! PATCH_DEST="$dest_xml" PATCH_JSON="$files_json" PATCH_XMLNAME="$PATCHES_XML_NAME" \
     PATCH_TITLEID="$title_id" PATCH_WANT="$want" python3 <<'PY'
import json, os, sys
import xml.etree.ElementTree as ET

dest, json_path = os.environ["PATCH_DEST"], os.environ["PATCH_JSON"]
xml_name, title_id = os.environ["PATCH_XMLNAME"], os.environ["PATCH_TITLEID"]
want = [p.strip() for p in os.environ["PATCH_WANT"].split(";") if p.strip()]

root = ET.parse(dest).getroot()            # raises if we wrote invalid XML
enabled = {m.get("Name") for m in root.findall(".//Metadata") if m.get("isEnabled") == "true"}
if set(want) != enabled:
    print(f"  ! enabled set mismatch — wanted {sorted(want)}, file has {sorted(enabled)}",
          file=sys.stderr)
    sys.exit(1)

with open(json_path, encoding="utf-8") as fh:  # raises if unparseable → silent skip
    data = json.load(fh)
if xml_name not in data or title_id not in data[xml_name]:
    print(f"  ! files.json does not map {xml_name} -> {title_id}", file=sys.stderr)
    sys.exit(1)
print("verified")
PY
then
  warn "Wrote the patch files but could not verify them — treat patches as NOT applied."
  disable_stale_patches
  prune_unusable_patch_dir
  exit 0
fi

ok "Patch file:  $dest_xml"
ok "files.json:  $files_json  (maps $PATCHES_XML_NAME -> $title_id)"
if [ "$profile" = deckborne ]; then
  ok "Enabled for profile '$profile' (target '$target'): $want"
else
  ok "Enabled for profile '$profile': $want"
fi
warn "These patches target game version 01.09 — they will not apply to another version."
