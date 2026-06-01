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
- Pluggable backends — Ollama first, OpenAI later (roadmap).
- Fill‑in‑the‑Middle (FIM) prompt format for better context awareness.

## Requirements

- Neovim ≥ 0.10
- [Ollama](https://ollama.com) with a code model pulled:
  ```bash
  ollama pull qwen2.5-coder:1.5b
  ```

## Installation

**lazy.nvim**
```lua
{
  "your-name/ghost.nvim",
  opts = {
    model = "qwen2.5-coder:1.5b",
  },
}
```

**packer**
```lua
use {
  "your-name/ghost.nvim",
  config = function()
    require("ghost").setup({ model = "qwen2.5-coder:1.5b" })
  end,
}
```

## Configuration

All options with their defaults:

```lua
require("ghost").setup({
  backend = "ollama",              -- "ollama" | "openai" (future)
  model = "qwen2.5-coder:1.5b",    -- model name on the backend
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
  → build FIM prompt (prefix + suffix split at cursor)
  → POST to Ollama
  → render response as gray virtual text
  → Tab accepts, Esc dismisses, keep typing auto-dismisses
```

## TODO

- [x] Auto-trigger with debounce timer
- [ ] Auto‑pull missing model via Ollama API
- [ ] Error handling / silent fallback when Ollama is down
- [ ] OpenAI‑compatible backend
- [x] Streaming responses
- [ ] Per‑filetype model routing

## License

MIT
