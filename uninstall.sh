#!/usr/bin/env bash
# DeckBorne uninstaller — reverses the install so you can test from a clean slate.
# Routed through install.sh so it shares the same USB logging.
#
#   bash uninstall.sh              # remove emulator, game, tile, config.toml (KEEPS saves + logs)
#   bash uninstall.sh --all        # also wipe shadPS4 config + SAVE DATA  (prompts; add -y to skip)
#   bash uninstall.sh --dry-run    # show what would be removed, change nothing
#   bash uninstall.sh --purge-logs # also clear old USB logs
exec bash "$(dirname "${BASH_SOURCE[0]}")/install.sh" uninstall "$@"
