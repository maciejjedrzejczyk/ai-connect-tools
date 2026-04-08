# lms-opencode

Bash utilities for connecting local AI coding tools to [LM Studio](https://lmstudio.ai) models via its OpenAI-compatible API (`localhost:1234`).

## Scripts

### `claudecode-lmstudio-sync.sh`

Interactive model picker that launches [Claude Code](https://docs.anthropic.com/en/docs/claude-code) against a locally running LM Studio model.

- Fetches available models from LM Studio
- Presents a numbered menu (remembers your last selection)
- Saves config to `~/.config/claude-lmstudio/config.json`
- Launches `claude` with `ANTHROPIC_BASE_URL` pointed at LM Studio

```bash
./claudecode-lmstudio-sync.sh
# or with extra claude args:
./claudecode-lmstudio-sync.sh --verbose
```

Override the LM Studio URL with `LMSTUDIO_URL` env var.

### `opencode-lmstudio-sync.sh`

Syncs LM Studio's downloaded models into [opencode](https://opencode.ai)'s config file.

- Reads models from LM Studio's `/v1/models` endpoint
- Diffs against `~/.config/opencode/opencode.json`
- Adds new models and removes stale ones
- Reports what changed

```bash
./opencode-lmstudio-sync.sh
```

## Requirements

- [LM Studio](https://lmstudio.ai) running with at least one model loaded
- `jq` and `curl`
- `claude` CLI (for the Claude Code script)
