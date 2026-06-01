local M = {}

--- Collect prefix (text before cursor) and suffix (text after cursor) from the
--- current buffer.
---@return string prefix, string suffix
function M.get_context()
	local buf = vim.api.nvim_get_current_buf()
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	local cursor = vim.api.nvim_win_get_cursor(0)
	local row = cursor[1]
	local col = cursor[2]

	local current_line = lines[row] or ""
	local before_cursor = current_line:sub(1, col)
	local after_cursor = current_line:sub(col + 1)

	local prefix_lines = {}
	for i = 1, row - 1 do
		table.insert(prefix_lines, lines[i] or "")
	end
	table.insert(prefix_lines, before_cursor)

	local suffix_lines = { after_cursor }
	for i = row + 1, #lines do
		table.insert(suffix_lines, lines[i] or "")
	end

	return table.concat(prefix_lines, "\n"), table.concat(suffix_lines, "\n")
end

--- Build a Fill-in-the-Middle prompt for Qwen/DeepSeek models.
---@param prefix string
---@param suffix string
---@return string
function M.build_prompt(prefix, suffix)
	return "<|fim_prefix|>" .. prefix .. "<|fim_suffix|>" .. suffix .. "<|fim_middle|>"
end

--- Request a completion from Ollama.
--- Calls `callback(text, nil)` on success, or `callback(nil, err_msg)` on error.
---@param prompt string
---@param fun(string?, string?) callback
function M.request_completion(prompt, callback)
	local config = require("ghost.config").options
	local url = config.ollama.url .. "/api/generate"

	local body = vim.fn.json_encode({
		model = config.model,
		prompt = prompt,
		stream = false,
		options = {
			num_predict = 128,
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
