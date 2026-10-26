#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/module-runtime.sh"
COLOR_MODULE_ID="niri"

COLORS_FILE="$STATE_DIR/user/generated/colors.json"
UPDATER="$XDG_CONFIG_HOME/niri/scripts/update-niri-colors.sh"

[[ -x "$UPDATER" ]] || { log_module "update-niri-colors.sh not found, skipping"; exit 0; }
[[ -s "$COLORS_FILE" ]] || { log_module "no palette yet, skipping"; exit 0; }

result="$("$UPDATER" "$COLORS_FILE")"
[[ "$result" == updated ]] && log_module "niri colours updated"
exit 0
