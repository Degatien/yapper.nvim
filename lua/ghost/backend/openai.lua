--- OpenAI / compatible backend for ghost.nvim.
---
--- Supports two API styles:
---   "completions" – legacy /v1/completions  (instruct models, native `suffix` param)
---   "chat"        – modern /v1/chat/completions (gpt-4, opencode, any chat‑compatible API)

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

--- Build a chat‑style FIM prompt.
--- Uses a <FILL_HERE> sentinel to mark the cursor position.
---@param prefix string
---@param suffix string
---@return table[]  list of {role, content} messages
local function build_chat_messages(prefix, suffix)
	return {
		{
			role = "system",
			content = "You are a code completion engine. Complete the code at <FILL_HERE>. "
				.. "Output only the new code that belongs at the cursor. "
				.. "Never repeat code above or below the cursor. "
				.. "Never wrap in markdown, never explain, never include backticks.",
		},
		{
			role = "user",
			content = prefix .. "<FILL_HERE>" .. suffix,
		},
	}
end

--- Extract text from a streaming chat chunk.
---@param choice table
---@return string
local function chat_delta_text(choice)
	local content = (choice.delta or {}).content
	if type(content) == "string" then
		return content
	end
	return ""
end

--- Extract text from a streaming completions chunk.
---@param choice table
---@return string
local function completions_delta_text(choice)
	if type(choice.text) == "string" then
		return choice.text
	end
	return ""
end

-- ── Streaming request ─────────────────────────────────────────────────────────

--- Fire a streaming completion request.
---
--- `on_chunk(text_so_far)` is called on each received token.
--- `on_finish(text, err)`  is called once when the stream ends or fails.
---
---@param prefix   string
---@param suffix   string
---@param on_chunk fun(string)
---@param on_finish fun(string?, string?)
---@return integer|nil job_id
function M.request_completion_stream(prefix, suffix, on_chunk, on_finish)
	local config = require("ghost.config").options
	local api_key = get_api_key()
	if not api_key then
		on_finish(nil, "OpenAI API key not set (config.openai.api_key or OPENAI_API_KEY)")
		return nil
	end

	local is_chat = config.openai.api_style == "chat"
	-- Normalise URL: append /chat/completions or /completions
	local base = config.openai.url:gsub("/+$", "")
	local url = base .. (is_chat and "/chat/completions" or "/completions")

	local ext = {}
	if is_chat then
		ext = {
			model = config.openai.model,
			messages = build_chat_messages(prefix, suffix),
			max_tokens = config.num_predict,
			temperature = 0.1,
			top_p = 0.9,
			stop = { "<|endoftext|>" },
			stream = true,
		}
	else
		ext = {
			model = config.openai.model,
			prompt = prefix,
			suffix = suffix,
			max_tokens = config.num_predict,
			temperature = 0.1,
			top_p = 0.9,
			stop = { "<|endoftext|>" },
			stream = true,
		}
	end
	local body = vim.fn.json_encode(ext)

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
	local get_delta = is_chat and chat_delta_text or completions_delta_text

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
				local line = buffer:sub(1, nl - 1)
				buffer = buffer:sub(nl + 1)

				if line:find("^data: ") == 1 then
					local payload = line:sub(7)
					if payload == "[DONE]" then
						break
					end
					local ok, result = pcall(vim.fn.json_decode, payload)
					if ok and result.choices and #result.choices > 0 then
						local text = get_delta(result.choices[1])
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
			elseif exit_code ~= 0 and acc ~= "" then
				-- Partial data despite non-zero exit — still return what we got
				on_finish(acc)
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

--- Send a blocking completion request.
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

	local is_chat = config.openai.api_style == "chat"
	local base = config.openai.url:gsub("/+$", "")
	local url = base .. (is_chat and "/chat/completions" or "/completions")

	local ext = {}
	if is_chat then
		ext = {
			model = config.openai.model,
			messages = build_chat_messages(prefix, suffix),
			max_tokens = config.num_predict,
			temperature = 0.1,
			top_p = 0.9,
			stop = { "<|endoftext|>" },
			stream = false,
		}
	else
		ext = {
			model = config.openai.model,
			prompt = prefix,
			suffix = suffix,
			max_tokens = config.num_predict,
			temperature = 0.1,
			top_p = 0.9,
			stop = { "<|endoftext|>" },
			stream = false,
		}
	end
	local body = vim.fn.json_encode(ext)

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
				callback(nil, "failed to parse response")
				return
			end
			if result.choices and #result.choices > 0 then
				local text
				if is_chat then
					local msg = result.choices[1].message
					text = msg and type(msg.content) == "string" and msg.content or ""
				else
					text = type(result.choices[1].text) == "string" and result.choices[1].text or ""
				end
				callback(text)
			else
				callback(nil, "empty response")
			end
		end,
	})

	if job_id <= 0 then
		callback(nil, "failed to start curl")
	end
end

return M
