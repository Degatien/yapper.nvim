--- Helpers to collect context, build prompts, and request completions.
---
--- Prompt strategy (tunable via config):
---   • context_window.prefix_lines   – how many lines above cursor to include
---   • context_window.suffix_lines   – how many lines below cursor to include
---   • num_predict                   – max tokens the model may generate

local M = {}

--- Collect prefix (text before cursor) and suffix (text after cursor).
--- Context is trimmed to `context_window` so the model focuses on nearby code.
---@return string prefix, string suffix
function M.get_context()
	local config = require("ghost.config").options
	local buf = vim.api.nvim_get_current_buf()
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	local cursor = vim.api.nvim_win_get_cursor(0)
	local row = cursor[1] -- 1‑based
	local col = cursor[2]

	local current_line = lines[row] or ""
	local before_cursor = current_line:sub(1, col)
	local after_cursor = current_line:sub(col + 1)

	-- Lines above cursor (limited to context_window.prefix_lines, closest first)
	local ctx = config.context_window
	local prefix_start = math.max(1, row - ctx.prefix_lines)
	local prefix_lines = {}
	for i = prefix_start, row - 1 do
		table.insert(prefix_lines, lines[i] or "")
	end
	table.insert(prefix_lines, before_cursor)

	-- Lines below cursor (limited to context_window.suffix_lines)
	local suffix_end = math.min(#lines, row + ctx.suffix_lines)
	local suffix_lines = { after_cursor }
	for i = row + 1, suffix_end do
		table.insert(suffix_lines, lines[i] or "")
	end

	return table.concat(prefix_lines, "\n"), table.concat(suffix_lines, "\n")
end

--- Build a Fill-in-the-Middle prompt for Qwen / DeepSeek / StarCoder models.
--- Includes a short language hint so the model knows what to generate.
---@param prefix  string
---@param suffix  string
---@return string
function M.build_prompt(prefix, suffix)
	local buf = vim.api.nvim_get_current_buf()
	local ft = vim.bo[buf].filetype

	-- Language tag – tells the model what language we're writing.
	local lang_tag = ("Language: %s"):format(ft ~= "" and ft or "text")

	return ("<|fim_prefix|>%s\n%s\n<|fim_suffix|>%s<|fim_middle|>"):format(
		lang_tag,
		prefix,
		suffix
	)
end

--- Send a completion request to Ollama (non‑streaming).
---
--- The callback receives `(text, nil)` on success, or `(nil, err_msg)` on failure.
---@param prompt   string
---@param callback fun(string?, string?)
function M.request_completion(prompt, callback)
	local config = require("ghost.config").options
	local url = config.ollama.url .. "/api/generate"

	local body = vim.fn.json_encode({
		model = config.model,
		prompt = prompt,
		stream = false,
		options = {
			num_predict = config.num_predict,
			-- Encourage natural code completions
			temperature = 0.1,
			top_p = 0.9,
		},
	})

	local args = {
		"curl",
		"-s",
		"-X",
		"POST",
		url,
		"-H",
		"Content-Type: application/json",
		"-d",
		body,
	}

	local stdout_data = ""
	local stderr_data = ""

	local job_id = vim.fn.jobstart(args, {
		stdout_buffered = true,
		on_stdout = function(_, data)
			if data then
				stdout_data = table.concat(data, "\n")
			end
		end,
		on_stderr = function(_, data)
			if data then
				stderr_data = table.concat(data, "\n")
			end
		end,
		on_exit = function(_, exit_code)
			if exit_code ~= 0 then
				callback(nil, "curl exited " .. exit_code .. ": " .. stderr_data)
				return
			end
			local ok, result = pcall(vim.fn.json_decode, stdout_data)
			if not ok then
				callback(nil, "failed to parse Ollama response")
				return
			end
			if result.response then
				-- Trim trailing whitespace / newlines only.
				local text = result.response:gsub("[\n ]*$", "")
				callback(text)
			else
				callback(nil, "empty response from model")
			end
		end,
	})

	if job_id <= 0 then
		callback(nil, "failed to start curl")
	end
end

return M
