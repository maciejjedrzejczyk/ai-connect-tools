#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib-lmstudio.sh"

CODEX_CONFIG="$HOME/.codex/config.toml"

# ── Ensure codex config exists
mkdir -p "$(dirname "$CODEX_CONFIG")"
[ -f "$CODEX_CONFIG" ] || touch "$CODEX_CONFIG"

# ── Fetch, pick, reload
model_ids=$(lms_fetch_models)
last_model=$(jq -r '.last_model // empty' "$SHARED_CONFIG" 2>/dev/null || true)
selected=$(lms_pick_model "$model_ids" "$last_model")
lms_reload_model "$selected"

# ── Save selection
lms_save_last_model "$selected"

profile=$(model_profile "$selected")
echo ""
echo "Launching Codex with: $selected"
echo "  Profile: $profile"
echo ""

export LMSTUDIO_API_KEY="lm-studio"
exec codex --oss --local-provider lmstudio --model "$selected" "$@"
