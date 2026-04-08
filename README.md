# ai-connect-tools

Bash utilities for connecting local AI coding tools to [LM Studio](https://lmstudio.ai) models via its OpenAI-compatible API (`localhost:1234`).

All scripts automatically configure models with optimal settings for AI TUI usage — large context windows (128K), flash attention, and model-family-specific sampling parameters — based on recommendations from [claude-code-tools](https://github.com/pchalasani/claude-code-tools/blob/main/docs/local-llm-setup.md).

## Configuration

All settings are centralized in `config.json` and shared across scripts via `lib-lmstudio.sh`:

```
config.json          ← shared settings, model profiles, last selected model
lib-lmstudio.sh      ← shared functions (fetch, pick, unload/load, save)
*-lmstudio-sync.sh   ← thin wrappers that source the lib and launch a TUI
```

Edit `config.json` to change defaults:

```json
{
  "lmstudio_url": "http://127.0.0.1:1234",
  "context_length": 131072,
  "flash_attention": true,
  "output_length": 65536,
  "last_model": null,
  "model_profiles": {
    "qwen3-coder-next|qwen3-coder.*80b": { "temperature": 1.0, "top_p": 0.95, "top_k": 40, "min_p": 0.01 },
    "nemotron":                           { "temperature": 0.6, "top_p": 0.95, "top_k": 40, "min_p": 0.01 },
    "gemma.*4":                           { "temperature": 1.0, "top_p": 0.95, "top_k": 64, "min_p": 0.01 },
    "default":                            { "temperature": 0.7, "top_p": 0.95, "top_k": 40, "min_p": 0.01 }
  }
}
```

Environment variables (`LMSTUDIO_URL`, `CONTEXT_LENGTH`, `OUTPUT_LENGTH`) override config values when set.

The `last_model` field is updated automatically after each model selection and shared across all scripts — pick a model in one script and it becomes the default in the others.

## Scripts

### `claudecode-lmstudio-sync.sh`

Interactive model picker that launches [Claude Code](https://docs.anthropic.com/en/docs/claude-code) against a locally running LM Studio model.

- Fetches available models from LM Studio
- Presents a numbered menu (remembers your last selection)
- **Unloads all loaded models**, then reloads the selected model via LM Studio's load API with `context_length=131072` and `flash_attention=true`
- Saves model config + recommended sampling params to `~/.config/claude-lmstudio/config.json`
- Sets `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` to prevent telemetry-induced port exhaustion on macOS
- Launches `claude` with `ANTHROPIC_BASE_URL` pointed at LM Studio

```bash
./claudecode-lmstudio-sync.sh
# or with extra claude args:
./claudecode-lmstudio-sync.sh --verbose
```

Override defaults with env vars:

```bash
LMSTUDIO_URL=http://192.168.1.10:1234 CONTEXT_LENGTH=65536 ./claudecode-lmstudio-sync.sh
```

### `opencode-lmstudio-sync.sh`

Interactive model picker that syncs LM Studio models into [opencode](https://opencode.ai)'s config and launches it.

- Syncs models from LM Studio's `/v1/models` into `~/.config/opencode/opencode.json`
- Adds new models (with `context: 131072`, `output: 65536` limits) and removes stale ones
- Presents a numbered menu (remembers your last selection)
- **Unloads all loaded models**, then reloads the selected one with `context_length=131072` and `flash_attention=true`
- Sets the selected model as the default in opencode.json (`"model": "lmstudio/<id>"`)
- Auto-scaffolds the `lmstudio` provider block if missing
- Saves per-model sampling profiles to `~/.config/opencode/lmstudio-profiles.json`
- Launches `opencode`

```bash
./opencode-lmstudio-sync.sh
# or with extra opencode args:
./opencode-lmstudio-sync.sh --verbose
```

Override defaults with env vars:

```bash
LMSTUDIO_URL=http://192.168.1.10:1234 CONTEXT_LENGTH=65536 OUTPUT_LENGTH=32768 ./opencode-lmstudio-sync.sh
```

### `codex-lmstudio-sync.sh`

Interactive model picker that launches [OpenAI Codex CLI](https://github.com/openai/codex) against a locally running LM Studio model.

- Fetches available models from LM Studio
- Presents a numbered menu (remembers your last selection)
- **Unloads all loaded models**, then reloads the selected one with `context_length=131072` and `flash_attention=true`
- Auto-adds the `lmstudio` provider to `~/.codex/config.toml` if missing
- Launches `codex --local-provider lmstudio-local --model <id>`

```bash
./codex-lmstudio-sync.sh
# or with extra codex args:
./codex-lmstudio-sync.sh --full-auto
```

Override defaults with env vars:

```bash
LMSTUDIO_URL=http://192.168.1.10:1234 CONTEXT_LENGTH=65536 ./codex-lmstudio-sync.sh
```

## Model Profiles

Model profiles in `config.json` map model name patterns (regex) to recommended sampling parameters (sourced from [local-llm-setup.md](https://github.com/pchalasani/claude-code-tools/blob/main/docs/local-llm-setup.md)):

| Model Pattern | temp | top_p | top_k | min_p |
|---|---|---|---|---|
| Qwen3-Coder-Next / 80B | 1.0 | 0.95 | 40 | 0.01 |
| Nemotron | 0.6 | 0.95 | 40 | 0.01 |
| Gemma 4 | 1.0 | 0.95 | 64 | 0.01 |
| Default (all others) | 0.7 | 0.95 | 40 | 0.01 |

All models are loaded with `context_length=131072` and `flash_attention=true` by default. These are load-time parameters applied via LM Studio's `POST /api/v1/models/load` endpoint. Sampling parameters (temperature, top_p, etc.) are inference-time settings — they're saved to config files for reference and applied per-request by the TUI tools.

## Requirements

- [LM Studio](https://lmstudio.ai) running with at least one model loaded
- `jq` and `curl`
- `claude` CLI (for the Claude Code script)
- `codex` CLI (for the Codex script)
- `opencode` CLI (for the opencode script)
