#!/usr/bin/env bash
# Shared functions for lms-opencode scripts. Source this, don't execute it.
# Usage: source "$(dirname "$0")/lib-lmstudio.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHARED_CONFIG="$SCRIPT_DIR/config.json"

[ -f "$SHARED_CONFIG" ] || { echo "Error: $SHARED_CONFIG not found." >&2; exit 1; }

# ── Read settings (env vars override config file)
LMSTUDIO_URL="${LMSTUDIO_URL:-$(jq -r '.lmstudio_url' "$SHARED_CONFIG")}"
CONTEXT_LENGTH="${CONTEXT_LENGTH:-$(jq -r '.context_length' "$SHARED_CONFIG")}"
FLASH_ATTENTION=$(jq -r '.flash_attention' "$SHARED_CONFIG")
OUTPUT_LENGTH="${OUTPUT_LENGTH:-$(jq -r '.output_length' "$SHARED_CONFIG")}"

# ── Model profile lookup: matches model ID against config patterns
model_profile() {
  local model="$1"
  local lmodel=$(echo "$model" | tr '[:upper:]' '[:lower:]')
  local result
  result=$(jq -r --arg m "$lmodel" '
    .model_profiles | to_entries |
    map(select(.key != "default" and ($m | test(.key; "i")))) |
    first // {value: .model_profiles.default} | .value
  ' "$SHARED_CONFIG" 2>/dev/null) || true
  [ -z "$result" ] || [ "$result" = "null" ] && \
    result=$(jq -r '.model_profiles.default' "$SHARED_CONFIG")
  echo "$result"
}

# ── Fetch model list from LM Studio
lms_fetch_models() {
  local response
  response=$(curl -sf "$LMSTUDIO_URL/v1/models" 2>/dev/null) || {
    echo "Error: Cannot reach LM Studio at $LMSTUDIO_URL" >&2; exit 1
  }
  echo "$response" | jq -r '.data[].id' | sort
}

# ── Interactive model picker. Prints selected model ID to stdout.
#    Menu and prompts go to stderr so callers can capture just the result.
lms_pick_model() {
  local model_ids="$1" last_model="${2:-}"
  local items=() default_idx="" i choice

  while IFS= read -r line; do items+=("$line"); done <<< "$model_ids"
  echo "Available LM Studio models:" >&2
  echo "" >&2
  for i in "${!items[@]}"; do
    local marker="  "
    if [ "${items[$i]}" = "$last_model" ]; then
      marker="* "
      default_idx=$((i+1))
    fi
    printf "  %s%d) %s\n" "$marker" $((i+1)) "${items[$i]}" >&2
  done
  echo "" >&2
  [ -n "$last_model" ] && echo "  (* = last used)" >&2

  local prompt="Select model"
  [ -n "$default_idx" ] && prompt="$prompt [$default_idx]"
  printf "\n%s: " "$prompt" >&2
  read -r choice </dev/tty

  [ -z "$choice" ] && [ -n "$default_idx" ] && choice="$default_idx"
  [ -z "$choice" ] && { echo "No selection made." >&2; exit 1; }
  if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#items[@]}" ]; then
    echo "Invalid selection." >&2; exit 1
  fi
  echo "${items[$((choice-1))]}"
}

# ── Unload all loaded LLMs, then load selected model
lms_reload_model() {
  local selected="$1"
  echo ""
  local loaded_ids
  loaded_ids=$(curl -sf "$LMSTUDIO_URL/api/v1/models" 2>/dev/null \
    | jq -r '.models[] | select(.type=="llm") | .loaded_instances[].id' 2>/dev/null || true)
  for iid in $loaded_ids; do
    echo "Unloading $iid..."
    curl -sf "$LMSTUDIO_URL/api/v1/models/unload" \
      -H "Content-Type: application/json" \
      -d "$(jq -n --arg id "$iid" '{instance_id:$id}')" >/dev/null 2>&1 || true
  done

  echo "Loading $selected (context=$CONTEXT_LENGTH, flash_attention=$FLASH_ATTENTION)..."
  local load_resp
  load_resp=$(curl -sf "$LMSTUDIO_URL/api/v1/models/load" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg m "$selected" --argjson c "$CONTEXT_LENGTH" --argjson fa "$FLASH_ATTENTION" \
      '{model:$m, context_length:$c, flash_attention:$fa}')" 2>/dev/null) || {
    echo "Warning: Could not load model via API." >&2; return
  }
  if [ -n "${load_resp:-}" ]; then
    local load_time
    load_time=$(echo "$load_resp" | jq -r '.load_time_seconds // "?"')
    echo "✓ Model loaded in ${load_time}s"
  fi
}

# ── Save last_model back to shared config
lms_save_last_model() {
  local selected="$1"
  local tmp=$(mktemp)
  jq --arg m "$selected" '.last_model = $m' "$SHARED_CONFIG" > "$tmp" && mv "$tmp" "$SHARED_CONFIG"
}
