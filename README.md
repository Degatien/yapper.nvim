# ghost.nvim

Inline tab-completion for Neovim. Like Copilot, but local, free, and yours.

![screenshot](https://img.shields.io/badge/status-alpha-orange)

## Features

- Ghost text rendered after the cursor via `nvim_buf_set_extmark`.
- Streaming responses — ghost appears token by token as the model generates.
- Multi‑line ghost rendering via `virt_lines` for function‑body completions.
- Auto‑trigger after a typing pause (default 300ms).
- Manual completion on `<Leader>c` (insert mode).
- Accept with `<Tab>`, dismiss with `<Esc>`.
- Pluggable backends — Ollama (local) and OpenAI (cloud).
- Fill‑in‑the‑Middle (FIM) prompt format for better context awareness.

## Requirements

- Neovim ≥ 0.10

**Ollama backend** (default):
- [Ollama](https://ollama.com) with a **base** code model (not instruct/chat):
  ```bash
  ollama pull deepseek-coder:6.7b
  ```
  Base models output raw code. Instruct models wrap completions in markdown — avoid them.
  Other tested models: `qwen2.5-coder:7b-base`, `deepseek-coder:1.3b` (lighter but weaker).

**OpenAI backend** (`backend = "openai"`):
- API key via `config.openai.api_key` or `OPENAI_API_KEY` env var
- An [instruct model](https://platform.openai.com/docs/models) that supports the `/v1/completions` endpoint (e.g. `gpt-3.5-turbo-instruct`).

## Installation

**lazy.nvim**
```lua
{
  "your-name/ghost.nvim",
  opts = {
    model = "deepseek-coder:6.7b",
  },
}
```

**packer**
```lua
use {
  "your-name/ghost.nvim",
  config = function()
    require("ghost").setup({ model = "deepseek-coder:6.7b" })
  end,
}
```

## Configuration

All options with their defaults:

```lua
require("ghost").setup({
  backend = "ollama",              -- "ollama" | "openai"
  model = "deepseek-coder:6.7b",   -- used by the Ollama backend
  debounce_ms = 300,               -- idle time (ms) before auto-trigger fires
  enabled = true,                  -- auto-trigger on/off
  keymaps = {
    manual = "<Leader>c",          -- manual completion (insert mode)
    toggle = "<Leader>ct",         -- toggle auto-trigger (normal mode)
    accept = "<Tab>",              -- accept suggestion (insert mode)
    dismiss = "<Esc>",             -- dismiss suggestion (insert mode)
  },
  ollama = {
    url = "http://localhost:11434",
  },
  openai = {
    url = "https://api.openai.com/v1",
    api_key = "",                  -- or set OPENAI_API_KEY env var
    model = "gpt-3.5-turbo-instruct",
  },
  context_window = {
    prefix_lines = 100,            -- lines above the cursor to include
    suffix_lines = 30,             -- lines below the cursor to include
  },
  num_predict = 256,               -- max tokens the model may generate
})
```

## Commands

| Command | Description |
|---------|-------------|
| `:GhostComplete` | Request a completion from the active backend |
| `:GhostToggle` | Enable / disable auto-trigger |

## How it works

```
Typing pause (300ms) → collect buffer context
  → build backend prompt (prefix + suffix split at cursor)
  → POST to Ollama / OpenAI
  → render response as gray virtual text
  → Tab accepts, Esc dismisses, keep typing auto-dismisses
```

## TODO

- [x] Auto-trigger with debounce timer
- [x] Streaming responses
- [x] Multi‑line ghost rendering (virt_lines)
- [x] FIM stop tokens + response cleanup
- [ ] Auto‑pull missing model via Ollama API
- [ ] Error handling / silent fallback when Ollama is down
- [x] OpenAI‑compatible backend
- [ ] Per‑filetype model routing

## License

MIT
