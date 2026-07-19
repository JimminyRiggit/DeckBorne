#!/usr/bin/env bash
# 10 — Install shadPS4: download the pinned v0.16 SDL zip, verify, extract the
# AppImage into ~/Applications/shadps4, verify the AppImage, make it executable.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"; load_env

step "Installing shadPS4 $SHADPS4_VERSION"

mkdir -p "$APP_DIR"
appimage="$APP_DIR/$SHADPS4_APPIMAGE_NAME"

# Idempotent: if a correct AppImage is already deployed, skip the download.
if [ -f "$appimage" ] && [ "$(sha256sum "$appimage" | awk '{print $1}')" = "$SHADPS4_APPIMAGE_SHA256" ]; then
  ok "shadPS4 already installed and verified — skipping download"
else
  # Prefer a bundled copy on the USB stick (offline-capable); else download.
  bundled="$DECKBORNE_ROOT/payloads/shadps4/$(basename "$SHADPS4_ZIP_URL")"
  tmp_zip="$(mktemp --suffix=.zip)"
  trap 'rm -f "$tmp_zip"' EXIT

  if [ -f "$bundled" ]; then
    log "Using bundled emulator zip from USB payload"
    cp "$bundled" "$tmp_zip"
  else
    log "Downloading $SHADPS4_ZIP_URL"
    curl -fL --progress-bar -o "$tmp_zip" "$SHADPS4_ZIP_URL" || die "download failed"
  fi

  verify_sha256 "$tmp_zip" "$SHADPS4_ZIP_SHA256"
  log "Extracting AppImage to $APP_DIR"
  unzip -o "$tmp_zip" "$SHADPS4_APPIMAGE_NAME" -d "$APP_DIR" >/dev/null
  verify_sha256 "$appimage" "$SHADPS4_APPIMAGE_SHA256"
fi

chmod +x "$appimage"
ok "shadPS4 ready: $appimage"
