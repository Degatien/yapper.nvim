--- Helpers to collect context, build prompts, and request completions.
---
--- Prompt strategy (tunable via config):
---   • context_window.prefix_lines   – how many lines above cursor to include
---   • context_window.suffix_lines   – how many lines below cursor to include
---   • num_predict                   – max tokens the model may generate
---
--- Two request modes:
---   • `request_completion`     – non‑streaming (used by `:GhostComplete`)
---   • `request_completion_stream` – streaming  (used by auto‑trigger)

local M = {}

-- ── Context ───────────────────────────────────────────────────────────────────

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

-- ── Prompt helpers ───────────────────────────────────────────────────────────

--- Build a Fill-in-the-Middle prompt for Qwen / DeepSeek / StarCoder models.
--- Keeps the FIM tokens clean – the model infers the language from context.
---@param prefix  string
---@param suffix  string
---@return string
local function build_fim_prompt(prefix, suffix)
	return ("<|fim_prefix|>%s<|fim_suffix|>%s<|fim_middle|>"):format(prefix, suffix)
end

-- ── Streaming state ──────────────────────────────────────────────────────────

local stream = {
	job_id = nil,
	buffer = "",
	accumulated = "",
	on_chunk = nil,
	on_finish = nil,
}

--- Cancel any in‑flight streaming request.
function M.cancel_stream()
	if stream.job_id then
		pcall(vim.fn.jobstop, stream.job_id)
		stream.job_id = nil
	end
	stream.buffer = ""
	stream.accumulated = ""
	stream.on_chunk = nil
	stream.on_finish = nil
end

-- ── Ollama streaming request ─────────────────────────────────────────────────

--- Fire a streaming completion request to Ollama.
---
--- `on_chunk(text_so_far)` is called on each received token.
--- `on_finish(text, err)`  is called once when the stream ends or fails.
---
---@param prefix   string
---@param suffix   string
---@param on_chunk fun(string)
---@param on_finish fun(string?, string?)
function M.request_completion_stream(prefix, suffix, on_chunk, on_finish)
	-- Cancel any prior stream first.
	M.cancel_stream()

	local config = require("ghost.config").options
	local url = config.ollama.url .. "/api/generate"
	local prompt = build_fim_prompt(prefix, suffix)

	local body = vim.fn.json_encode({
		model = config.model,
		prompt = prompt,
		stream = true,
		options = {
			num_predict = config.num_predict,
			temperature = 0.1,
			top_p = 0.9,
		},
	})

	local args = {
		"curl",
		"-sN", -- silent + no‑buffer (streaming)
		"-X",
		"POST",
		url,
		"-H",
		"Content-Type: application/json",
		"-d",
		body,
	}

	stream.on_chunk = on_chunk
	stream.on_finish = on_finish

	local stderr_data = ""

	stream.job_id = vim.fn.jobstart(args, {
		stdout_buffered = false,
		on_stdout = function(_, data)
			if not data then
				return
			end
			-- Re‑join lines (jobstart strips newlines) to reconstruct raw stream.
			stream.buffer = stream.buffer .. table.concat(data, "\n")

			-- Process every complete line in the buffer.
			while true do
				local nl = stream.buffer:find("\n")
				if not nl then
					break
				end
				local line = stream.buffer:sub(1, nl - 1):gsub("^%s+", ""):gsub("%s+$", "")
				stream.buffer = stream.buffer:sub(nl + 1)

				if line ~= "" then
					local ok, result = pcall(vim.fn.json_decode, line)
					if ok and result.response then
						stream.accumulated = stream.accumulated .. result.response
						if not result.done then
							if stream.on_chunk then
								stream.on_chunk(stream.accumulated)
							end
						end
					end
				end
			end
		end,
		on_stderr = function(_, data)
			if data then
				stderr_data = table.concat(data, "\n")
			end
		end,
		on_exit = function(_, exit_code)
			local job_finished = (stream.job_id ~= nil)
			stream.job_id = nil

			local text = stream.accumulated:gsub("[\n ]*$", "")
			stream.buffer = ""
			stream.accumulated = ""
			local cb = stream.on_finish
			stream.on_chunk = nil
			stream.on_finish = nil

			if cb then
				if exit_code ~= 0 and text == "" then
					cb(nil, "curl exited " .. exit_code .. ": " .. stderr_data)
				else
					cb(text)
				end
			end
		end,
	})

	if stream.job_id <= 0 then
		local cb = stream.on_finish
		M.cancel_stream()
		if cb then
			cb(nil, "failed to start curl")
		end
	end
end

-- ── Non‑streaming request (used by `:GhostComplete`) ─────────────────────────

--- Send a blocking completion request to Ollama.
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
