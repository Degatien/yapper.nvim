--- OpenAI backend for ghost.nvim.
--- Uses the `/v1/completions` endpoint with the native `suffix` parameter
--- for Fill-in-the-Middle.  Requires an `instruct` model (e.g. `gpt-3.5-turbo-instruct`).

local M = {}

-- ── Helpers ────────────────────────────────────────────────────────────────────

--- Resolve the API key from config or environment.
---@return string?
local function get_api_key()
	local config = require("ghost.config").options
	if config.openai.api_key and config.openai.api_key ~= "" then
		return config.openai.api_key
	end
	return vim.env.OPENAI_API_KEY
end

-- ── Streaming request ─────────────────────────────────────────────────────────

--- Fire a streaming completion request to OpenAI.
---
--- `on_chunk(text_so_far)` is called on each received token.
--- `on_finish(text, err)`  is called once when the stream ends or fails.
---
---@param prefix   string
---@param suffix   string
---@param on_chunk fun(string)
---@param on_finish fun(string?, string?)
---@return integer|nil job_id  the jobstart id, or nil on failure
function M.request_completion_stream(prefix, suffix, on_chunk, on_finish)
	local config = require("ghost.config").options
	local api_key = get_api_key()
	if not api_key then
		on_finish(nil, "OpenAI API key not set (config.openai.api_key or OPENAI_API_KEY)")
		return nil
	end

	local url = config.openai.url .. "/completions"

	local body = vim.fn.json_encode({
		model = config.openai.model,
		prompt = prefix,
		suffix = suffix,
		max_tokens = config.num_predict,
		temperature = 0.1,
		top_p = 0.9,
		stop = { "<|endoftext|>" },
		stream = true,
	})

	local args = {
		"curl",
		"-sN",
		"-X",
		"POST",
		url,
		"-H",
		"Content-Type: application/json",
		"-H",
		"Authorization: Bearer " .. api_key,
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

			-- Process every complete line in the SSE buffer.
			while true do
				local nl = buffer:find("\n")
				if not nl then
					break
				end
				local line = buffer:sub(1, nl - 1)
				buffer = buffer:sub(nl + 1)

				-- OpenAI SSE format:  data: <json>\n
				if line:find("^data: ") == 1 then
					local payload = line:sub(7)

					-- End-of-stream marker
					if payload == "[DONE]" then
						break
					end

					local ok, result = pcall(vim.fn.json_decode, payload)
					if ok and result.choices and #result.choices > 0 then
						local text = result.choices[1].text or ""
						if text ~= "" then
							acc = acc .. text
							if result.choices[1].finish_reason == nil then
								on_chunk(acc)
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

--- Send a blocking completion request to OpenAI.
---
--- The callback receives `(text, nil)` on success, or `(nil, err_msg)` on failure.
---@param prefix   string
---@param suffix   string
---@param callback fun(string?, string?)
function M.request_completion(prefix, suffix, callback)
	local config = require("ghost.config").options
	local api_key = get_api_key()
	if not api_key then
		callback(nil, "OpenAI API key not set (config.openai.api_key or OPENAI_API_KEY)")
		return
	end

	local url = config.openai.url .. "/completions"

	local body = vim.fn.json_encode({
		model = config.openai.model,
		prompt = prefix,
		suffix = suffix,
		max_tokens = config.num_predict,
		temperature = 0.1,
		top_p = 0.9,
		stop = { "<|endoftext|>" },
		stream = false,
	})

	local args = {
		"curl",
		"-s",
		"-X",
		"POST",
		url,
		"-H",
		"Content-Type: application/json",
		"-H",
		"Authorization: Bearer " .. api_key,
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
				callback(nil, "failed to parse OpenAI response")
				return
			end
			if result.choices and #result.choices > 0 then
				callback(result.choices[1].text)
			else
				callback(nil, "empty response from OpenAI")
			end
		end,
	})

	if job_id <= 0 then
		callback(nil, "failed to start curl")
	end
end

return M
