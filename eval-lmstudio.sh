#!/usr/bin/env bash
# Headless evaluation harness: runs Claude Code, opencode, and Codex CLI
# against the same LM Studio model with identical prompt, captures metrics,
# and prints a comparison report.
set -euo pipefail

LMSTUDIO_URL="${LMSTUDIO_URL:-http://127.0.0.1:1234}"
CONTEXT_LENGTH="${CONTEXT_LENGTH:-131072}"
EVAL_DIR="${EVAL_DIR:-./eval-runs}/$(date +%Y%m%d-%H%M%S)"

# ── Usage ────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: $0 [options] "your prompt here"

Options:
  -m, --model <id>    Model to use (skips picker)
  -t, --tools <list>  Comma-separated TUIs to run (default: claude,codex,opencode)
  -h, --help          Show this help

Environment:
  LMSTUDIO_URL    LM Studio base URL  (default: http://127.0.0.1:1234)
  CONTEXT_LENGTH  Context window size  (default: 131072)
  EVAL_DIR        Base directory for eval output (default: ./eval-runs/<timestamp>)

Example:
  $0 "Create a python script that prints fibonacci numbers"
  $0 -m qwen3-coder-next "Refactor main.py to use async/await"
  $0 -t claude,codex "Write a hello world web server in Go"
EOF
  exit 0
}

# ── Parse args ───────────────────────────────────────────────────────────
MODEL=""
TOOLS="claude,codex,opencode"
PROMPT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -m|--model) MODEL="$2"; shift 2 ;;
    -t|--tools) TOOLS="$2"; shift 2 ;;
    -h|--help)  usage ;;
    *)          PROMPT="$1"; shift ;;
  esac
done

[ -z "$PROMPT" ] && { echo "Error: prompt is required." >&2; usage; }

# ── Model profiles (shared with other scripts) ──────────────────────────
model_profile() {
  local model="$1"
  case "$model" in
    *[Qq]wen3-[Cc]oder-[Nn]ext*|*[Qq]wen3-[Cc]oder*80[Bb]*)
      echo '{"context_length":131072,"flash_attention":true,"temperature":1.0,"top_p":0.95,"top_k":40,"min_p":0.01}' ;;
    *[Nn]emotron*)
      echo '{"context_length":131072,"flash_attention":true,"temperature":0.6,"top_p":0.95,"top_k":40,"min_p":0.01}' ;;
    *[Gg]emma*4*)
      echo '{"context_length":131072,"flash_attention":true,"temperature":1.0,"top_p":0.95,"top_k":64,"min_p":0.01}' ;;
    *[Gg][Ll][Mm]*4*)
      echo '{"context_length":131072,"flash_attention":true,"temperature":0.7,"top_p":0.95,"top_k":40,"min_p":0.01}' ;;
    *)
      echo '{"context_length":131072,"flash_attention":true,"temperature":0.7,"top_p":0.95,"top_k":40,"min_p":0.01}' ;;
  esac
}

# ── Fetch models & pick ──────────────────────────────────────────────────
models=$(curl -sf "$LMSTUDIO_URL/v1/models" 2>/dev/null) || {
  echo "Error: Cannot reach LM Studio at $LMSTUDIO_URL" >&2; exit 1
}
model_ids=$(echo "$models" | jq -r '.data[].id' | sort)
[ -z "$model_ids" ] && { echo "No models found in LM Studio." >&2; exit 1; }

if [ -z "$MODEL" ]; then
  items=()
  while IFS= read -r line; do items+=("$line"); done <<< "$model_ids"
  echo "Available LM Studio models:"
  echo ""
  for i in "${!items[@]}"; do
    printf "  %d) %s\n" $((i+1)) "${items[$i]}"
  done
  printf "\nSelect model: "
  read -r choice
  if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#items[@]}" ]; then
    echo "Invalid selection." >&2; exit 1
  fi
  MODEL="${items[$((choice-1))]}"
fi

# ── Validate / fuzzy-match model ID against available models ─────────
if ! echo "$model_ids" | grep -qxF "$MODEL"; then
  match=$(echo "$model_ids" | grep -F "$MODEL" | head -1 || true)
  if [ -n "$match" ]; then
    echo "Resolved '$MODEL' → '$match'"
    MODEL="$match"
  else
    echo "Error: Model '$MODEL' not found in LM Studio." >&2
    echo "Available:" >&2
    echo "$model_ids" | sed 's/^/  /' >&2
    exit 1
  fi
fi

# ── Load model in LM Studio ─────────────────────────────────────────────
profile=$(model_profile "$MODEL")
ctx=$(echo "$profile" | jq -r '.context_length')
fa=$(echo "$profile" | jq -r '.flash_attention')

echo ""
loaded_ids=$(curl -sf "$LMSTUDIO_URL/api/v1/models" 2>/dev/null \
  | jq -r '.models[] | select(.type=="llm") | .loaded_instances[].id' 2>/dev/null || true)
for iid in $loaded_ids; do
  echo "Unloading $iid..."
  curl -sf "$LMSTUDIO_URL/api/v1/models/unload" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg id "$iid" '{instance_id:$id}')" >/dev/null 2>&1 || true
done

echo "Loading $MODEL (context=$ctx, flash_attention=$fa)..."
load_resp=$(curl -sf "$LMSTUDIO_URL/api/v1/models/load" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg m "$MODEL" --argjson c "$ctx" --argjson fa "$fa" \
    '{model:$m, context_length:$c, flash_attention:$fa}')" 2>/dev/null) || {
  echo "Warning: Could not load model via API." >&2
}
if [ -n "${load_resp:-}" ]; then
  lt=$(echo "$load_resp" | jq -r '.load_time_seconds // "?"')
  echo "✓ Model loaded in ${lt}s"
fi

# ── Prepare eval directory ───────────────────────────────────────────────
mkdir -p "$EVAL_DIR"
echo "$PROMPT" > "$EVAL_DIR/prompt.txt"
jq -n --arg model "$MODEL" --arg prompt "$PROMPT" --arg tools "$TOOLS" \
  --argjson profile "$profile" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{model:$model, prompt:$prompt, tools:($tools|split(",")), profile:$profile, started_at:$ts}' \
  > "$EVAL_DIR/eval-config.json"

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  Eval: $EVAL_DIR"
echo "  Model: $MODEL"
echo "  Profile: $profile"
echo "  Prompt: ${PROMPT:0:80}$([ ${#PROMPT} -gt 80 ] && echo '...')"
echo "═══════════════════════════════════════════════════════"

# ── Runner functions ─────────────────────────────────────────────────────

run_claude() {
  local dir
  dir="$(cd "$EVAL_DIR" && pwd)/claude"
  mkdir -p "$dir/workspace"
  echo "[claude] Starting..."

  local start=$SECONDS
  cd "$dir/workspace"
  echo "$PROMPT" | \
  ANTHROPIC_BASE_URL="$LMSTUDIO_URL" \
  ANTHROPIC_AUTH_TOKEN="lmstudio" \
  CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
  claude --print \
    --verbose \
    --dangerously-skip-permissions \
    --model "$MODEL" \
    --output-format stream-json \
    > "$dir/raw.jsonl" 2>"$dir/stderr.log" || true
  cd - >/dev/null
  local elapsed=$(( SECONDS - start ))

  # Extract metrics from stream-json output
  local input_tokens output_tokens tool_calls
  input_tokens=$(jq -s '[.[] | select(.type=="result") | .input_tokens // 0] | add // 0' "$dir/raw.jsonl" 2>/dev/null || echo 0)
  output_tokens=$(jq -s '[.[] | select(.type=="result") | .output_tokens // 0] | add // 0' "$dir/raw.jsonl" 2>/dev/null || echo 0)
  # Count tool_use messages as tool calls
  tool_calls=$(jq -s '[.[] | select(.type=="assistant") | .message.content[]? | select(.type=="tool_use")] | length' "$dir/raw.jsonl" 2>/dev/null || echo 0)
  # Count assistant turns as iterations
  local iterations
  iterations=$(jq -s '[.[] | select(.type=="assistant")] | length' "$dir/raw.jsonl" 2>/dev/null || echo 0)

  jq -n --arg tool "claude" --argjson elapsed "$elapsed" \
    --argjson input_tokens "$input_tokens" --argjson output_tokens "$output_tokens" \
    --argjson tool_calls "$tool_calls" --argjson iterations "$iterations" \
    '{tool:$tool, elapsed_seconds:$elapsed, input_tokens:$input_tokens, output_tokens:$output_tokens, total_tokens:($input_tokens+$output_tokens), tool_calls:$tool_calls, iterations:$iterations}' \
    > "$dir/metrics.json"

  echo "[claude] Done in ${elapsed}s"
}

run_codex() {
  local dir
  dir="$(cd "$EVAL_DIR" && pwd)/codex"
  mkdir -p "$dir/workspace"
  # Init a git repo so codex doesn't complain
  git -C "$dir/workspace" init -q 2>/dev/null || true
  echo "[codex] Starting..."

  local start=$SECONDS
  LMSTUDIO_API_KEY="lm-studio" \
  codex exec \
    --dangerously-bypass-approvals-and-sandbox \
    --provider lmstudio \
    -m "$MODEL" \
    -C "$dir/workspace" \
    --skip-git-repo-check \
    --json \
    "$PROMPT" \
    > "$dir/raw.jsonl" 2>"$dir/stderr.log" || true
  local elapsed=$(( SECONDS - start ))

  # Extract metrics from JSONL events
  local input_tokens output_tokens tool_calls iterations
  input_tokens=$(jq -s '[.[].usage?.input_tokens // 0] | add // 0' "$dir/raw.jsonl" 2>/dev/null || echo 0)
  output_tokens=$(jq -s '[.[].usage?.output_tokens // 0] | add // 0' "$dir/raw.jsonl" 2>/dev/null || echo 0)
  tool_calls=$(jq -s '[.[] | select(.type=="function_call" or .type=="tool_call")] | length' "$dir/raw.jsonl" 2>/dev/null || echo 0)
  iterations=$(jq -s '[.[] | select(.type=="message" and .role=="assistant")] | length' "$dir/raw.jsonl" 2>/dev/null || echo 0)

  # Fallback: count lines with "exec" events as tool calls if structured parsing yields 0
  if [ "$tool_calls" -eq 0 ]; then
    tool_calls=$(grep -c '"type":"exec"' "$dir/raw.jsonl" 2>/dev/null || echo 0)
  fi
  if [ "$iterations" -eq 0 ]; then
    iterations=$(grep -c '"type":"message"' "$dir/raw.jsonl" 2>/dev/null || echo 0)
  fi

  jq -n --arg tool "codex" --argjson elapsed "$elapsed" \
    --argjson input_tokens "$input_tokens" --argjson output_tokens "$output_tokens" \
    --argjson tool_calls "$tool_calls" --argjson iterations "$iterations" \
    '{tool:$tool, elapsed_seconds:$elapsed, input_tokens:$input_tokens, output_tokens:$output_tokens, total_tokens:($input_tokens+$output_tokens), tool_calls:$tool_calls, iterations:$iterations}' \
    > "$dir/metrics.json"

  echo "[codex] Done in ${elapsed}s"
}

run_opencode() {
  local dir
  dir="$(cd "$EVAL_DIR" && pwd)/opencode"
  mkdir -p "$dir/workspace"
  echo "[opencode] Starting..."

  # Ensure model exists in opencode.json (same logic as opencode-lmstudio-sync.sh)
  local oc_config="$HOME/.config/opencode/opencode.json"
  mkdir -p "$(dirname "$oc_config")"
  [ -f "$oc_config" ] || echo '{"$schema":"https://opencode.ai/config.json"}' > "$oc_config"
  local tmp
  tmp=$(mktemp)
  # Scaffold lmstudio provider if missing
  jq --arg url "$LMSTUDIO_URL/v1" '.provider.lmstudio //= {
    "npm": "@ai-sdk/openai-compatible",
    "name": "LM Studio (local)",
    "options": {"baseURL": $url}
  }' "$oc_config" > "$tmp" && mv "$tmp" "$oc_config"
  # Ensure this model exists in the provider's model list
  tmp=$(mktemp)
  jq --arg id "$MODEL" --argjson ctx "$CONTEXT_LENGTH" \
    '.provider.lmstudio.models[$id] //= {name: $id, limit: {context: $ctx, output: ($ctx/2)}}' \
    "$oc_config" > "$tmp" && mv "$tmp" "$oc_config"

  local start=$SECONDS
  opencode run \
    --dangerously-skip-permissions \
    -m "lmstudio/$MODEL" \
    --dir "$dir/workspace" \
    --format json \
    "$PROMPT" \
    > "$dir/raw.jsonl" 2>"$dir/stderr.log" || true
  local elapsed=$(( SECONDS - start ))

  # Try to get session ID from the JSON output and export full metrics
  local session_id
  session_id=$(jq -r 'select(.sessionID != null) | .sessionID' "$dir/raw.jsonl" 2>/dev/null | head -1 || true)
  if [ -z "$session_id" ]; then
    session_id=$(jq -r 'select(.session != null) | .session' "$dir/raw.jsonl" 2>/dev/null | head -1 || true)
  fi

  # Export session data if we got an ID
  if [ -n "$session_id" ]; then
    opencode export "$session_id" > "$dir/session-export.json" 2>/dev/null || true
  fi

  # Extract metrics from JSON events
  local input_tokens output_tokens tool_calls iterations
  input_tokens=$(jq -s '[.[].usage?.input_tokens // .[].inputTokens // 0] | add // 0' "$dir/raw.jsonl" 2>/dev/null || echo 0)
  output_tokens=$(jq -s '[.[].usage?.output_tokens // .[].outputTokens // 0] | add // 0' "$dir/raw.jsonl" 2>/dev/null || echo 0)
  tool_calls=$(jq -s '[.[] | select(.type=="tool_call" or .type=="tool-call" or .type=="tool_use")] | length' "$dir/raw.jsonl" 2>/dev/null || echo 0)
  iterations=$(jq -s '[.[] | select(.type=="assistant" or .type=="message")] | length' "$dir/raw.jsonl" 2>/dev/null || echo 0)

  # Fallback: try session export for token counts
  if [ "$input_tokens" -eq 0 ] && [ -f "$dir/session-export.json" ]; then
    input_tokens=$(jq '[.messages[]?.usage?.inputTokens // 0] | add // 0' "$dir/session-export.json" 2>/dev/null || echo 0)
    output_tokens=$(jq '[.messages[]?.usage?.outputTokens // 0] | add // 0' "$dir/session-export.json" 2>/dev/null || echo 0)
    tool_calls=$(jq '[.messages[]? | select(.role=="assistant") | .content[]? | select(.type=="tool_use" or .type=="tool-call")] | length' "$dir/session-export.json" 2>/dev/null || echo 0)
    iterations=$(jq '[.messages[]? | select(.role=="assistant")] | length' "$dir/session-export.json" 2>/dev/null || echo 0)
  fi

  jq -n --arg tool "opencode" --argjson elapsed "$elapsed" \
    --argjson input_tokens "$input_tokens" --argjson output_tokens "$output_tokens" \
    --argjson tool_calls "$tool_calls" --argjson iterations "$iterations" \
    '{tool:$tool, elapsed_seconds:$elapsed, input_tokens:$input_tokens, output_tokens:$output_tokens, total_tokens:($input_tokens+$output_tokens), tool_calls:$tool_calls, iterations:$iterations}' \
    > "$dir/metrics.json"

  echo "[opencode] Done in ${elapsed}s"
}

# ── Run selected tools sequentially ──────────────────────────────────────
IFS=',' read -ra TOOL_LIST <<< "$TOOLS"
for tool in "${TOOL_LIST[@]}"; do
  case "$tool" in
    claude)   run_claude ;;
    codex)    run_codex ;;
    opencode) run_opencode ;;
    *) echo "Unknown tool: $tool" >&2 ;;
  esac
done

# ── Generate comparison report ───────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════"
echo "  EVALUATION REPORT"
echo "═══════════════════════════════════════════════════════"
echo "  Model:  $MODEL"
echo "  Prompt: ${PROMPT:0:80}$([ ${#PROMPT} -gt 80 ] && echo '...')"
echo "  Dir:    $EVAL_DIR"
echo "───────────────────────────────────────────────────────"
printf "  %-10s %8s %10s %11s %10s %6s\n" "Tool" "Time(s)" "In Tokens" "Out Tokens" "Tool Calls" "Turns"
echo "───────────────────────────────────────────────────────"

for tool in "${TOOL_LIST[@]}"; do
  mf="$EVAL_DIR/$tool/metrics.json"
  [ -f "$mf" ] || continue
  printf "  %-10s %8s %10s %11s %10s %6s\n" \
    "$tool" \
    "$(jq -r '.elapsed_seconds' "$mf")" \
    "$(jq -r '.input_tokens' "$mf")" \
    "$(jq -r '.output_tokens' "$mf")" \
    "$(jq -r '.tool_calls' "$mf")" \
    "$(jq -r '.iterations' "$mf")"
done
echo "═══════════════════════════════════════════════════════"

# ── Save combined report ─────────────────────────────────────────────────
jq -s '.' "$EVAL_DIR"/*/metrics.json > "$EVAL_DIR/report.json" 2>/dev/null || true
echo ""
echo "Full report: $EVAL_DIR/report.json"
echo "Raw output:  $EVAL_DIR/<tool>/raw.jsonl"
