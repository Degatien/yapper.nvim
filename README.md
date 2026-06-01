# yapper.nvim

Inline code completion for Neovim. Like Copilot, but local, free, and yours.

Yapper text rendered at the cursor — streams token by token, auto-triggers after a typing pause, and supports FIM (Fill-in-the-Middle) for context-aware completions.

## Features

- **Yapper text** rendered after the cursor via `nvim_buf_set_extmark` (virtual text and `virt_lines` for multi-line completions).
- **Streaming** — completions appear token by token as the model generates.
- **Auto-trigger** — fires after a configurable typing pause (`debounce_ms`).
- **Manual completion** — `:YapperComplete` or `<Leader>c` in insert mode.
- **Accept / dismiss** — `<Tab>` accepts, `<Esc>` dismisses, any keystroke cancels mid-flight requests.
- **FIM (Fill-in-the-Middle)** — prefix + suffix sent to the model for context-aware completions that don't regenerate the rest of the file.
- **Prefix-only fallback** — when FIM returns empty (cursor inside an open/close pair), retries without suffix so the model still generates a suggestion.
- **Smart context** — tree-sitter powered: imports, enclosing function/struct signatures, and recent lines near the cursor.
- **LSP enrichment** — optionally resolves type definitions from across the project and includes them in the prompt.
- **Comment wrapping** — long comment lines are automatically wrapped at 80 characters.
- **Chatty-line detection** — truncates completions when the model switches from code to explanations.
- **Loading indicator** — a subtle `⟐` appears while the model is thinking.
- **Pluggable backends** — Ollama (local) and OpenAI (cloud).

## Requirements

- **Neovim ≥ 0.10**
- **tree-sitter** parser for your language (for smart context; falls back to simple context otherwise)

### Ollama backend (default)

- [Ollama](https://ollama.com) with a **base** code completion model:
  ```bash
  ollama pull deepseek-coder:6.7b-base
  ```

  > **Important:** Use **base** models (e.g. `deepseek-coder:6.7b-base`, `qwen2.5-coder:7b-base`), not instruct/chat variants. Base models have no chat template and output raw code. Chat/instruct models wrap completions in markdown or chatter.

### OpenAI backend

- API key via `config.openai.api_key` or the `OPENAI_API_KEY` environment variable.
- Two API styles (set via `config.openai.api_style`):
  - `"completions"` — legacy `/v1/completions` with native `suffix` support. Use with instruct models like `gpt-3.5-turbo-instruct`.
  - `"chat"` — modern `/v1/chat/completions`. Works with any chat model (gpt-4, opencode, etc.).

## Installation

### lazy.nvim

```lua
{
  "Degatien/yapper.nvim",
  opts = {
    model = "deepseek-coder:6.7b-base",
  },
}
```

### packer.nvim

```lua
use {
  "Degatien/yapper.nvim",
  config = function()
    require("yapper").setup({ model = "deepseek-coder:6.7b-base" })
  end,
}
```

## Configuration

All options and their defaults:

```lua
require("yapper").setup({
  -- Backend selection
  backend = "ollama",               -- "ollama" | "openai"
  model = "deepseek-coder:6.7b",   -- model name for the active backend

  -- Behaviour
  debounce_ms = 300,                -- idle time (ms) before auto-trigger fires
  enabled = true,                   -- auto-trigger on/off
  num_predict = 256,                -- max tokens the model may generate
  debug = false,                    -- log raw model responses & cleanup steps

  -- Keymaps (insert mode unless noted)
  keymaps = {
    manual = "<Leader>c",           -- trigger manual completion
    toggle = "<Leader>ct",          -- toggle auto-trigger (normal mode)
    accept = "<Tab>",               -- accept the yapper suggestion
    dismiss = "<Esc>",              -- dismiss the yapper suggestion
  },

  -- Ollama backend options
  ollama = {
    url = "http://localhost:11434",
  },

  -- OpenAI backend options
  openai = {
    url = "https://api.openai.com/v1",
    api_key = "",                   -- or set OPENAI_API_KEY env var
    model = "gpt-3.5-turbo-instruct",
    api_style = "completions",      -- "completions" | "chat"
  },

  -- Context window: how much of the buffer to send to the model
  context_window = {
    strategy = "smart",             -- "smart" | "simple"
    prefix_lines = 200,             -- lines above the cursor
    suffix_lines = 50,              -- lines below the cursor
    lsp_enrich = false,             -- resolve type definitions via LSP
    lsp_max_types = 3,              -- max types to look up (adds latency)
  },
})
```

### Context strategies

| Strategy | Description |
|----------|-------------|
| `"smart"` | (**default**) Includes imports, all enclosing function/struct/class signatures, and recent lines near the cursor. Uses tree-sitter to walk the ancestor chain of structural nodes. |
| `"simple"` | Contiguous line window around the cursor. Faster but provides less structural context. |

### LSP enrichment

When `context_window.lsp_enrich = true`, yapper.nvim extracts type names from the surrounding code (function signatures, type annotations) and uses the LSP `workspace/symbol` request to find their definitions across the project. The resolved definitions are prepended to the prompt so the model understands the types it's working with — even from other files.

Enable this if you have a fast LSP (e.g. gopls, rust-analyzer, typescript-language-server). Each lookup adds ~300ms.

## Backend examples

### Ollama (local)

```lua
require("yapper").setup({
  backend = "ollama",
  model = "qwen2.5-coder:7b-base",
  debounce_ms = 500,
  num_predict = 64,
  context_window = {
    strategy = "smart",
    lsp_enrich = true,
  },
})
```

### Ollama with reduced latency

```lua
require("yapper").setup({
  backend = "ollama",
  model = "deepseek-coder:1.3b",   -- smaller, faster model
  debounce_ms = 200,               -- faster trigger
  num_predict = 32,                -- fewer tokens = faster
  context_window = {
    prefix_lines = 80,
    suffix_lines = 20,
  },
})
```

### OpenAI (GPT-3.5 Turbo instruct)

```lua
require("yapper").setup({
  backend = "openai",
  openai = {
    api_key = vim.env.OPENAI_API_KEY,
    model = "gpt-3.5-turbo-instruct",
    api_style = "completions",
  },
})
```

### opencode Go / any OpenAI-compatible API

```lua
require("yapper").setup({
  backend = "openai",
  openai = {
    url = "https://api.openai.com/v1",   -- or your custom endpoint
    api_key = vim.env.OPENAI_API_KEY,
    model = "gpt-4o-mini",
    api_style = "chat",
  },
})
```

## Commands

| Command | Description |
|---------|-------------|
| `:YapperComplete` | Request a completion from the active backend |
| `:YapperToggle` | Enable / disable the auto-trigger |

## How it works

```
User types → keystroke cancels any in-flight request
           → debounce timer restarts
           → after debounce_ms of idle time:
              1. Collect prefix + suffix (context module)
                 - Smart: imports + ancestor signatures + recent lines
                 - (optional) LSP enrichment: cross-file type definitions
              2. Build FIM prompt: <|fim_prefix|>prefix<|fim_suffix|>suffix<|fim_middle|>
              3. POST streaming request to Ollama / OpenAI
              4. Render response as gray virtual text (token by token)
                 - Loading indicator ⟐ shown while waiting
              5. On finish: cleanup (strip FIM tokens, wrap long comments,
                 detect chatty lines, check suffix overlap)
                 - If empty: retry prefix-only with truncated num_predict
           → Tab accepts, Esc dismisses, any keystroke auto-dismisses
```

## Contributing

1. Fork the repository
2. Create a feature branch (`git checkout -b feat/my-feature`)
3. Make your changes
4. Run the linter and tests (if available)
5. Commit with a conventional commit message (`feat:`, `fix:`, `docs:`, etc.)
6. Push and open a pull request

### Code style

- Lua files under `lua/yapper/` follow the Neovim community conventions.
- Module structure:
  - `config.lua` — default options and setup
  - `context.lua` — prefix/suffix collection (smart + simple strategies)
  - `context_lsp.lua` — LSP-powered type resolution
  - `completion.lua` — request dispatch, response cleanup, stream cancellation
  - `render.lua` — yapper text rendering (extmarks, loading indicator)
  - `init.lua` — auto-trigger logic, autocmds, commands, keymaps
  - `plugin/yapper.lua` — plugin entry-point for lazy loading
  - `backend/ollama.lua` — Ollama backend (`/api/generate` + FIM)
  - `backend/openai.lua` — OpenAI backend (`/v1/completions` or `/v1/chat/completions`)

## License

MIT
