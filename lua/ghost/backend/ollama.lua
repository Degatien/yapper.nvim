--- Ollama backend for ghost.nvim.
--- Uses the `/api/chat` endpoint with a completion-oriented system prompt.
--- The model's chat template wraps the request properly, and the system
--- prompt overrides the baked-in "programming assistant" instructions.
---
--- Note: suffix is currently unused — the model receives only the code
--- before the cursor. This works for most inline completions and avoids
--- the FIM token issues present in this model's Ollama packaging.

local M = {}

-- ── Streaming request ─────────────────────────────────────────────────────────

--- Fire a streaming completion request to Ollama.
---
--- `on_chunk(text_so_far)` is called on each received token.
--- `on_finish(text, err)`  is called once when the stream ends or fails.
---
---@param prefix   string   code before cursor
---@param suffix   string   code after cursor (currently unused in chat mode)
---@param on_chunk fun(string)
---@param on_finish fun(string?, string?)
---@return integer|nil job_id  the jobstart id, or nil on failure
function M.request_completion_stream(prefix, suffix, on_chunk, on_finish)
	local config = require("ghost.config").options
	local url = config.ollama.url .. "/api/chat"

	local body = vim.fn.json_encode({
		model = config.model,
		stream = true,
		messages = {
			{
				role = "system",
				content = "You are a code completion engine. Complete ONLY what belongs at the cursor position — the current expression, statement, or block being typed. Do NOT continue writing the rest of the file. Do NOT regenerate code that already follows the cursor. Stop as soon as the completion is logically complete. Wrap comments at 80 characters. Output only raw code, no explanations, no markdown, no backticks, no language tags.",
			},
			{
				role = "user",
				content = prefix,
			},
		},
		options = {
			num_predict = config.num_predict,
			temperature = 0.1,
			top_p = 0.9,
			stop = { "```" },
		},
	})

	local args = {
		"curl",
		"-sN",
		"-X",
		"POST",
		url,
		"-H",
		"Content-Type: application/json",
		"-d",
		body,
	}

	local acc = ""
	local buffer = ""
	local stderr_data = ""

	local job_id = vim.fn.jobstart(args, {
		stdout_buffered = false,
		on_stdout = function(_, data)
			if not data then
				return
			end
			buffer = buffer .. table.concat(data, "\n")

			while true do
				local nl = buffer:find("\n")
				if not nl then
					break
				end
				local line = buffer:sub(1, nl - 1):gsub("^%s+", ""):gsub("%s+$", "")
				buffer = buffer:sub(nl + 1)

				if line ~= "" then
					local ok, result = pcall(vim.fn.json_decode, line)
					if ok and result.message and result.message.content then
						acc = acc .. result.message.content
						if not result.done then
							on_chunk(acc)
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
			if exit_code ~= 0 and acc == "" then
				on_finish(nil, "curl exited " .. exit_code .. ": " .. stderr_data)
			else
				on_finish(acc)
			end
		end,
	})

	if job_id <= 0 then
		on_finish(nil, "failed to start curl")
		return nil
	end

	return job_id
end

-- ── Non‑streaming request ─────────────────────────────────────────────────────

--- Send a blocking completion request to Ollama.
---
--- The callback receives `(text, nil)` on success, or `(nil, err_msg)` on failure.
---@param prefix   string   code before cursor
---@param suffix   string   code after cursor (currently unused in chat mode)
---@param callback fun(string?, string?)
function M.request_completion(prefix, suffix, callback)
	local config = require("ghost.config").options
	local url = config.ollama.url .. "/api/chat"

	local body = vim.fn.json_encode({
		model = config.model,
		stream = false,
		messages = {
			{
				role = "system",
				content = "You are a code completion engine. Complete ONLY what belongs at the cursor position — the current expression, statement, or block being typed. Do NOT continue writing the rest of the file. Do NOT regenerate code that already follows the cursor. Stop as soon as the completion is logically complete. Wrap comments at 80 characters. Output only raw code, no explanations, no markdown, no backticks, no language tags.",
			},
			{
				role = "user",
				content = prefix,
			},
		},
		options = {
			num_predict = config.num_predict,
			temperature = 0.1,
			top_p = 0.9,
			stop = { "```" },
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
			callback(result.message.content)
		end,
	})

	if job_id <= 0 then
		callback(nil, "failed to start curl")
	end
end

return M
