#!/usr/bin/env bash
set -euo pipefail

CONFIG="$HOME/.config/claude-lmstudio/config.json"
LMSTUDIO_URL="${LMSTUDIO_URL:-http://127.0.0.1:1234}"

mkdir -p "$(dirname "$CONFIG")"
[ -f "$CONFIG" ] || echo '{}' > "$CONFIG"

# Fetch models from LM Studio
models=$(curl -sf "$LMSTUDIO_URL/v1/models" 2>/dev/null) || {
  echo "Error: Cannot reach LM Studio at $LMSTUDIO_URL" >&2; exit 1
}
model_ids=$(echo "$models" | jq -r '.data[].id' | sort)
[ -z "$model_ids" ] && { echo "No models found in LM Studio." >&2; exit 1; }

# Load last used model
last_model=$(jq -r '.last_model // empty' "$CONFIG" 2>/dev/null || true)

# Build menu
items=()
while IFS= read -r line; do items+=("$line"); done <<< "$model_ids"
echo "Available LM Studio models:"
echo ""
default_idx=""
for i in "${!items[@]}"; do
  marker="  "
  if [ "${items[$i]}" = "$last_model" ]; then
    marker="* "
    default_idx=$((i+1))
  fi
  printf "  %s%d) %s\n" "$marker" $((i+1)) "${items[$i]}"
done
echo ""
[ -n "$last_model" ] && echo "  (* = last used)"

prompt="Select model"
[ -n "$default_idx" ] && prompt="$prompt [$default_idx]"
printf "\n%s: " "$prompt"
read -r choice

# Handle default
[ -z "$choice" ] && [ -n "$default_idx" ] && choice="$default_idx"
[ -z "$choice" ] && { echo "No selection made." >&2; exit 1; }

# Validate
if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#items[@]}" ]; then
  echo "Invalid selection." >&2; exit 1
fi
selected="${items[$((choice-1))]}"

# Save config
jq -n --arg model "$selected" --arg url "$LMSTUDIO_URL" \
  '{last_model: $model, base_url: $url, updated_at: (now | todate)}' > "$CONFIG"

echo ""
echo "Launching Claude Code with: $selected"
echo ""

# Launch claude with LM Studio env
export ANTHROPIC_BASE_URL="$LMSTUDIO_URL"
export ANTHROPIC_AUTH_TOKEN="lmstudio"
exec claude --model "$selected" "$@"
