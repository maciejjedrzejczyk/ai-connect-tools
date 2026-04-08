#!/usr/bin/env bash
# Syncs LM Studio downloaded models with opencode.json config
set -euo pipefail

CONFIG="$HOME/.config/opencode/opencode.json"
LMSTUDIO_URL="http://127.0.0.1:1234/v1/models"

# Fetch models from LM Studio
response=$(curl -sf "$LMSTUDIO_URL" 2>/dev/null) || {
  echo "Error: Cannot reach LM Studio at $LMSTUDIO_URL" >&2
  exit 1
}

# Build new models object from LM Studio response, then merge into config
lm_models=$(echo "$response" | jq '[.data[].id] | sort | map({(.): {name: .}}) | add // {}')

# Read current config models
current_models=$(jq '.provider.lmstudio.models // {}' "$CONFIG")

# Compare
added=$(jq -n --argjson new "$lm_models" --argjson old "$current_models" '$new | keys - ($old | keys) | .[]' 2>/dev/null)
removed=$(jq -n --argjson new "$lm_models" --argjson old "$current_models" '$old | keys - ($new | keys) | .[]' 2>/dev/null)

if [ -z "$added" ] && [ -z "$removed" ]; then
  echo "✓ Already in sync — no changes needed."
  exit 0
fi

# Apply update
tmp=$(mktemp)
jq --argjson models "$lm_models" '.provider.lmstudio.models = $models' "$CONFIG" > "$tmp"
mv "$tmp" "$CONFIG"

# Report
[ -n "$added" ] && echo "Added:" && echo "$added" | sed 's/^/  + /'
[ -n "$removed" ] && echo "Removed:" && echo "$removed" | sed 's/^/  - /'
echo "✓ opencode.json updated."
