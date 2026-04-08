#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib-lmstudio.sh"

CONFIG="$HOME/.config/opencode/opencode.json"

# ── Ensure config exists with lmstudio provider scaffold
mkdir -p "$(dirname "$CONFIG")"
[ -f "$CONFIG" ] || echo '{"$schema":"https://opencode.ai/config.json"}' > "$CONFIG"

tmp=$(mktemp)
jq --arg url "$LMSTUDIO_URL/v1" '.provider.lmstudio //= {
  "npm": "@ai-sdk/openai-compatible",
  "name": "LM Studio (local)",
  "options": {"baseURL": $url}
}' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"

# ── Fetch models and sync into opencode.json
model_ids=$(lms_fetch_models)

lm_models=$(echo "$model_ids" | jq -Rsc --argjson ctx "$CONTEXT_LENGTH" --argjson out "$OUTPUT_LENGTH" '
  split("\n") | map(select(length>0)) |
  map({(.): {name: ., limit: {context: $ctx, output: $out}}}) | add // {}
')

current_models=$(jq '.provider.lmstudio.models // {}' "$CONFIG")
added=$(jq -n --argjson new "$lm_models" --argjson old "$current_models" \
  '$new | keys - ($old | keys) | .[]' 2>/dev/null || true)
removed=$(jq -n --argjson new "$lm_models" --argjson old "$current_models" \
  '$old | keys - ($new | keys) | .[]' 2>/dev/null || true)

if [ -n "$added" ] || [ -n "$removed" ]; then
  tmp=$(mktemp)
  jq --argjson models "$lm_models" '.provider.lmstudio.models = $models' "$CONFIG" > "$tmp"
  mv "$tmp" "$CONFIG"
  [ -n "$added" ] && echo "Added:" && echo "$added" | sed 's/^/  + /'
  [ -n "$removed" ] && echo "Removed:" && echo "$removed" | sed 's/^/  - /'
  echo "✓ opencode.json synced."
  echo ""
fi

# ── Pick, reload
last_model=$(jq -r '.last_model // empty' "$SHARED_CONFIG" 2>/dev/null || true)
selected=$(lms_pick_model "$model_ids" "$last_model")
lms_reload_model "$selected"

# ── Save selection
lms_save_last_model "$selected"
tmp=$(mktemp)
jq --arg m "lmstudio/$selected" '.model = $m' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"

# ── Save sampling profiles
profile=$(model_profile "$selected")
PROFILE_FILE="$(dirname "$CONFIG")/lmstudio-profiles.json"
profiles="{}"
while IFS= read -r mid; do
  [ -z "$mid" ] && continue
  p=$(model_profile "$mid")
  profiles=$(echo "$profiles" | jq --arg k "$mid" --argjson v "$p" '. + {($k): $v}')
done <<< "$model_ids"
echo "$profiles" | jq '.' > "$PROFILE_FILE"

echo ""
echo "Launching opencode with: lmstudio/$selected"
echo "  Profile: $profile"
echo ""

exec opencode "$@"
