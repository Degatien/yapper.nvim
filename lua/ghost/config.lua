local M = {}

M.defaults = {
	backend = "ollama",
	model = "qwen2.5-coder:1.5b",
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
