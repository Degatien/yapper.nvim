local M = {}

M.defaults = {
	backend = "ollama",
	model = "qwen2.5-coder:7b-base",
	debounce_ms = 300,
	enabled = true,
	keymaps = {
		manual = "<Leader>c",
		toggle = "<Leader>ct",
		accept = "<Tab>",
		dismiss = "<Esc>",
	},
	ollama = {
		url = "http://localhost:11434",
	},
	openai = {
		url = "https://api.openai.com/v1",
		api_key = "",
	},
	--- Context window: how much of the buffer to include around the cursor.
	--- Larger = more context but longer latency / higher memory.
	context_window = {
		prefix_lines = 100, -- lines above the cursor
		suffix_lines = 30,  -- lines below the cursor
	},
	--- Max tokens the model may generate per completion.
	num_predict = 256,
}

M.options = {}

function M.setup(opts)
	if M._setup_done then
		return
	end
	M._setup_done = true
	M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
end

return M
