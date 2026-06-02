--- Ollama backend for yapper.nvim.
--- Uses `/api/generate` for code completion.
---
--- Supports two FIM modes:
---   - `fim_suffix_api = false` (default): manually constructs FIM tokens in the
---     prompt. Works with deepseek-coder-base and similar models.
---   - `fim_suffix_api = true`: uses Ollama's native `suffix` API parameter.
---     Required for models with built-in FIM templates (qwen2.5-coder, codegemma).

local M = {}

-- ── Prompt formatting ──────────────────────────────────────────────────────────

--- Build a Fill-in-the-Middle prompt for the configured model.
--- When `fim_suffix_api` is true, returns just the prefix (the suffix is sent
--- via a separate API parameter). Otherwise, manually wraps prefix and suffix
--- with FIM control tokens (deepseek-coder, etc.).
---@param prefix string
---@param suffix string
---@return string prompt, string|nil api_suffix
function M.build_prompt(prefix, suffix)
	local config = require("yapper.config").options
	if config.ollama.fim_suffix_api then
		return prefix, suffix
	end
	return ("<|fim_prefix|>%s<|fim_suffix|>%s<|fim_middle|>"):format(prefix, suffix), nil
end

-- ── Streaming request ─────────────────────────────────────────────────────────

--- Fire a streaming completion request to Ollama.
---
--- `on_chunk(text_so_far)` is called on each received token.
--- `on_finish(text, err)`  is called once when the stream ends or fails.
---
---@param prefix   string   code before cursor
---@param suffix   string   code after cursor
---@param on_chunk fun(string)
---@param on_finish fun(string?, string?)
---@return integer|nil job_id  the jobstart id, or nil on failure
function M.request_completion_stream(prefix, suffix, on_chunk, on_finish)
	local config = require("yapper.config").options
	local url = config.ollama.url .. "/api/generate"
	local prompt, api_suffix = M.build_prompt(prefix, suffix)

	local request = {
		model = config.model,
		prompt = prompt,
		stream = true,
		options = {
			num_predict = config.num_predict,
			temperature = 0.1,
			top_p = 0.9,
			stop = { "<|fim_end|>", "<|endoftext|>" },
		},
	}
	if api_suffix then
		request.suffix = api_suffix
	end
	if config.ollama.keep_alive then
		request.keep_alive = config.ollama.keep_alive
	end
	local body = vim.fn.json_encode(request)

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
					if ok and result.response then
						acc = acc .. result.response
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
---@param suffix   string   code after cursor
---@param callback fun(string?, string?)
function M.request_completion(prefix, suffix, callback)
	local config = require("yapper.config").options
	local url = config.ollama.url .. "/api/generate"
	local prompt, api_suffix = M.build_prompt(prefix, suffix)

	local request = {
		model = config.model,
		prompt = prompt,
		stream = false,
		options = {
			num_predict = config.num_predict,
			temperature = 0.1,
			top_p = 0.9,
			stop = { "<|fim_end|>", "<|endoftext|>" },
		},
	}
	if api_suffix then
		request.suffix = api_suffix
	end
	if config.ollama.keep_alive then
		request.keep_alive = config.ollama.keep_alive
	end
	local body = vim.fn.json_encode(request)

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
			callback(result.response)
		end,
	})

	if job_id <= 0 then
		callback(nil, "failed to start curl")
	end
end

return M
