#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib-lmstudio.sh"

CLAUDE_CONFIG="$HOME/.config/claude-lmstudio/config.json"
mkdir -p "$(dirname "$CLAUDE_CONFIG")"
[ -f "$CLAUDE_CONFIG" ] || echo '{}' > "$CLAUDE_CONFIG"

# ── Fetch, pick, reload
model_ids=$(lms_fetch_models)
last_model=$(jq -r '.last_model // empty' "$SHARED_CONFIG" 2>/dev/null || true)
selected=$(lms_pick_model "$model_ids" "$last_model")
lms_reload_model "$selected"

# ── Save selection
lms_save_last_model "$selected"
profile=$(model_profile "$selected")
jq -n --arg model "$selected" --arg url "$LMSTUDIO_URL" --argjson profile "$profile" \
  '{last_model:$model, base_url:$url, model_profile:$profile, updated_at:(now|todate)}' > "$CLAUDE_CONFIG"

echo ""
echo "Launching Claude Code with: $selected"
echo "  Profile: $profile"
echo ""

export ANTHROPIC_BASE_URL="$LMSTUDIO_URL"
export ANTHROPIC_AUTH_TOKEN="lmstudio"
export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
exec claude --model "$selected" "$@"
