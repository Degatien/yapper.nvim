--- Dispatches completion requests to the active backend.
---
--- Provides shared helpers (context collection, response cleanup, stream cancellation)
--- and routes `request_completion` / `request_completion_stream` to whichever
--- backend is selected via `config.backend`.

local M = {}

-- ── Backend loader ────────────────────────────────────────────────────────────

--- Load the currently active backend module by name.
---@return table
local function load_backend()
	local config = require("yapper.config").options
	local ok, backend = pcall(require, "yapper.backend." .. config.backend)
	if not ok then
		error("yapper.nvim: unknown backend '" .. config.backend .. "'")
	end
	return backend
end

-- ── Context ───────────────────────────────────────────────────────────────────

--- Collect prefix and suffix for the current cursor position.
--- Delegates to `yapper.context` which implements the configured strategy.
---@return string prefix, string suffix
function M.get_context()
	return require("yapper.context").get_context()
end

-- ── Comment helpers ──────────────────────────────────────────────────────────

--- Detect the comment prefix on a line (if any), accounting for leading whitespace.
--- Returns (indent, comment_char, body) or nil.
--- Supports: //, #, --, ;, %
---@param line string
---@return string|nil indent, string|nil comment_char, string|nil body
local function parse_comment(line)
	local patterns = {
		"^(%s*)(//+)%s*(.*)$",
		"^(%s*)(#+)%s*(.*)$",
		"^(%s*)(%-%-+)%s*(.*)$",
		"^(%s*)(;+)%s*(.*)$",
		"^(%s*)(%%+)%s*(.*)$",
	}
	for _, pat in ipairs(patterns) do
		local indent, cc, body = line:match(pat)
		if indent ~= nil and cc ~= nil and cc ~= "" then
			return indent, cc, body
		end
	end
	return nil
end

-- ── Chatty-line detection ────────────────────────────────────────────────────

--- Heuristic: does this line look like the model explaining itself
--- rather than writing code?
---@param line string
---@return boolean
local function is_chatty_line(line)
	if not line or line == "" then
		return false
	end
	local trimmed = line:gsub("^%s*(.-)%s*$", "%1")

	-- Empty / whitespace-only lines are fine
	if trimmed == "" then
		return false
	end

	-- Markdown fences: ```, ~~~ — model switched to explanation mode
	if trimmed:match("^```") or trimmed:match("^~~~") then
		return true
	end

	-- Markdown headings: ## Title, ### Subtitle
	if trimmed:match("^#+%s") then
		return true
	end

	-- Bullet points: - item, * item
	if trimmed:match("^[-*]%s") then
		return true
	end

	-- Plaintext transition phrases: the model has switched to explaining.
	-- Match sentence-style openers that almost never appear in code.
	if trimmed:match("^[Hh]ere'?s?%s") -- "Here is", "Here's"
		or trimmed:match("^[Tt]his%s") -- "This function", "This code"
		or trimmed:match("^[Ii]t%s%l") -- "It seems", "it looks" (but not "it x =" )
		or trimmed:match("^[Ii]'[lm]%s") -- "I'm", "I'll"
		or trimmed:match("^[Yy]ou'?r?e?'?s?%s") -- "You are", "You can", "You're", "You'll"
		or trimmed:match("^[Ll]et'?s?%s") -- "Let me", "Let's"
		or trimmed:match("^[Tt]o%s%u") -- "To use", "To implement" (capital after "To")
		or trimmed:match("^[Ss]ure[,!.]?$")
		or trimmed:match("^[Nn]ote[:%s]") -- "Note:", "Note that"
		or trimmed:match("^[Rr]emember[:%s]") -- "Remember:", "Remember to"
		or trimmed:match("^[Bb]ased on%s") -- "Based on the code"
		or trimmed:match("^[Gg]iven%s") -- "Given the context"
		or trimmed:match("^[Bb]e careful") or trimmed:match("^[Dd]on'?t%s") then
		return true
	end

	-- Prose lines with markdown backtick formatting: `likeThis`
	-- This is a telltale sign the model is writing prose, not code.
	if trimmed:match("`[%w_]+`") and not trimmed:match("[{}%(%)%=;:<>,]") then
		return true
	end

	-- Closing markdown fence
	if trimmed:match("^```$") or trimmed:match("^~~~$") then
		return true
	end

	-- If the line is a comment AND reads like prose (not a code annotation)
	local _, _, body = parse_comment(trimmed)
	if body then
		body = body:gsub("^%s*(.-)%s*$", "%1")
		-- Short code annotations are fine: "// TODO", "// FIXME", "// 1.", "// --"
		if #body <= 6 then return false end
		-- Annotation keywords are fine
		if body:match("^[A-Z]+[%s:]") then return false end
		-- If the comment body has no code symbols and looks like a sentence, it's chatty
		if body:match("%.[%s]*$") or body:match("[!?][%s]*$") then
			return true
		end
		if #body > 50 and not body:match("[{}%(%)%=;,]") then
			return true
		end
		-- Starts with a chatty word
		if body:match("^[Hh]ere") or body:match("^[Tt]his") or body:match("^[Yy]ou")
			or body:match("^[Ww]e") or body:match("^[Ii]f you") or body:match("^[Tt]he ")
			or body:match("^[Ff]irst") or body:match("^[Tt]hen") or body:match("^[Nn]ext")
			or body:match("^[Ff]inally") or body:match("^[Bb]ecause") then
			return true
		end
	end

	-- Pure prose with no code syntax at all — uncommon, but possible
	if #trimmed > 30
		and not trimmed:match("[{}%(%)%[%]=;:,.<>%+%-%*/%%@#&|^!~`$]")
		and not trimmed:match("^%s+")
		and not trimmed:match("^[%a_]+%s+[%a_]+$") then
		return true
	end

	return false
end

--- Scan from the first line and truncate at the first chatty line.
---@param text string
---@return string
local function truncate_at_chat(text)
	if not text or text == "" then
		return text
	end
	local lines = vim.split(text, "\n")
	local result = {}
	for _, line in ipairs(lines) do
		if is_chatty_line(line) then
			break -- truncate at the first chatty line
		end
		table.insert(result, line)
	end
	return table.concat(result, "\n")
end

-- ── Comment wrapping ─────────────────────────────────────────────────────────

--- Wrap a line of text at word boundaries to fit within max_width.
--- Returns a list of wrapped lines.
---@param prefix   string   indent + comment char + space (e.g. "  // ")
---@param text     string   the comment body to wrap
---@param max_width number
---@return string[]
local function wrap_text(prefix, text, max_width)
	local words = {}
	for w in text:gmatch("%S+") do
		table.insert(words, w)
	end
	local lines = {}
	local current = ""
	for _, word in ipairs(words) do
		local sep = (#current > 0) and " " or ""
		if #current + #sep + #word > max_width - #prefix and #current > 0 then
			table.insert(lines, current)
			current = word
		else
			current = current .. sep .. word
		end
	end
	if #current > 0 then
		table.insert(lines, current)
	end
	local result = {}
	for i, line in ipairs(lines) do
		if i == 1 then
			table.insert(result, prefix .. line)
		else
			table.insert(result, prefix .. line)
		end
	end
	return result
end

--- Wrap comment lines that exceed max_width.
---@param text      string
---@param max_width number
---@return string
local function wrap_comment_lines(text, max_width)
	if not text or text == "" then
		return text
	end
	local lines = vim.split(text, "\n")
	local result = {}
	for _, line in ipairs(lines) do
		if #line > max_width then
			local indent, cc, body = parse_comment(line)
			if indent and cc and body then
				local prefix = indent .. cc .. " "
				local wrapped = wrap_text(prefix, body, max_width)
				for _, w in ipairs(wrapped) do
					table.insert(result, w)
				end
			else
				table.insert(result, line)
			end
		else
			table.insert(result, line)
		end
	end
	return table.concat(result, "\n")
end

-- ── Response cleanup ─────────────────────────────────────────────────────────

local function log(msg, text1, text2)
	local cfg = require("yapper.config").options
	if cfg and cfg.debug then
		local lines = {}
		table.insert(lines, "[yapper-debug] " .. msg)
		if text1 then table.insert(lines, "  raw:    " .. vim.inspect(text1)) end
		if text2 then table.insert(lines, "  suffix: " .. vim.inspect(text2)) end
		vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
	end
end

--- Clean up whitespace from the model's output and truncate if the
--- completion starts regenerating code already present in the suffix.
---@param text   string   the raw completion from the model
---@param suffix string   code after the cursor (used for overlap detection)
---@return string
local function cleanup_completion(text, suffix)
	log("cleanup_completion called", text, suffix)
	if not text then
		return ""
	end
	-- Strip leading newlines (model often starts with one)
	text = text:gsub("^[\n]+", "")
	-- Strip trailing whitespace / newlines
	text = text:gsub("[\n ]*$", "")
	-- If nothing meaningful remains, return empty
	if text == "" or text:match("^%s*$") then
		return ""
	end

	-- Strip any leaked FIM tokens the model may have emitted
	text = text:gsub("<|fim_[a-z_]+|>", "")

	-- Truncate at first chatty line (model explaining itself)
	text = truncate_at_chat(text)

	-- Wrap comment lines at 80 characters
	text = wrap_comment_lines(text, 80)

	-- Suffix overlap check: if the completion starts regenerating code that
	-- already exists after the cursor, truncate at the overlap point.
	-- This prevents the model from "continuing the file" beyond the cursor.
	if suffix and suffix ~= "" then
		local compl_lines = vim.split(text, "\n")
		local suff_lines = vim.split(suffix, "\n")

		-- Find where the first significant (non-empty) suffix line appears
		-- in the completion with 2+ consecutive matching lines.
		for si = 1, #suff_lines do
			if suff_lines[si]:match("%S") then
				for ci = 1, #compl_lines do
					if compl_lines[ci] == suff_lines[si] then
						-- Check if the next line also matches (confirms overlap)
						if ci < #compl_lines and si < #suff_lines then
							if compl_lines[ci + 1] == suff_lines[si + 1] then
								-- 2+ consecutive matches — truncate before ci
								if ci <= 2 then
									-- If overlap starts in the first 2 lines, the
									-- completion is likely regenerating the suffix.
									return ""
								end
								local truncated = {}
								for i = 1, ci - 1 do
									table.insert(truncated, compl_lines[i])
								end
								return table.concat(truncated, "\n")
							end
						end
					end
				end
				-- Only check the first non-empty suffix line
				break
			end
		end
	end

	log("cleanup result", text)
	return text
end

-- ── Streaming state ──────────────────────────────────────────────────────────

local stream = {
	job_id = nil,
	on_chunk = nil,
	on_finish = nil,
}

--- Cancel any in‑flight streaming request.
function M.cancel_stream()
	if stream.job_id then
		pcall(vim.fn.jobstop, stream.job_id)
		stream.job_id = nil
	end
	stream.on_chunk = nil
	stream.on_finish = nil
end

-- ── Streaming request dispatcher ─────────────────────────────────────────────

--- Fire a streaming completion request using the active backend.
---
--- `on_chunk(text_so_far)` is called on each received token.
--- `on_finish(text, err)`  is called once when the stream ends or fails.
---
---@param prefix   string
---@param suffix   string
---@param on_chunk fun(string)
---@param on_finish fun(string?, string?)
function M.request_completion_stream(prefix, suffix, on_chunk, on_finish)
	M.cancel_stream()

	local backend = load_backend()

	stream.on_chunk = on_chunk
	stream.on_finish = on_finish

	-- Track whether we've already done a prefix-only retry
	local retried = false

	stream.job_id = backend.request_completion_stream(prefix, suffix,
		function(text_so_far)
			if stream.on_chunk then
				stream.on_chunk(text_so_far)
			end
		end,
		function(text, err)
			if err then
				if stream.on_finish then
					stream.on_finish(nil, err)
				end
				stream.job_id = nil
				stream.on_chunk = nil
				stream.on_finish = nil
				return
			end

			local cleaned = cleanup_completion(text or "", suffix)

			-- If FIM returned empty and we haven't retried yet, fall back to
			-- prefix-only completion.  This handles cases where the suffix
			-- immediately closes the current construct (e.g. cursor is inside
			-- console.log("|") — the model sees the closing "); and thinks
			-- "nothing to fill").
			if cleaned == "" and suffix ~= "" and not retried then
				retried = true
				-- Reduce num_predict temporarily for the prefix-only retry
				local cfg = require("yapper.config").options
				local saved_num = cfg.num_predict
				cfg.num_predict = math.min(saved_num or 64, 16)
				stream.job_id = backend.request_completion_stream(prefix, "",
					function(text_so_far)
						if stream.on_chunk then
							-- Truncate at first newline during streaming too
							local nl = text_so_far:find("\n")
							if nl then
								text_so_far = text_so_far:sub(1, nl - 1)
							end
							stream.on_chunk(text_so_far)
						end
					end,
					function(text2, err2)
						cfg.num_predict = saved_num -- restore
						if err2 then
							if stream.on_finish then
								stream.on_finish(nil, err2)
							end
						else
							local cleaned2 = cleanup_completion(text2 or "", "")
							-- Prefix-only: truncate at first newline to avoid
							-- regenerating the rest of the file.
							local nl = cleaned2:find("\n")
							if nl then
								cleaned2 = cleaned2:sub(1, nl - 1)
							end
							if stream.on_finish then
								stream.on_finish(cleaned2)
							end
						end
						stream.job_id = nil
						stream.on_chunk = nil
						stream.on_finish = nil
					end
				)
				return
			end

			if stream.on_finish then
				stream.on_finish(cleaned)
			end
			stream.job_id = nil
			stream.on_chunk = nil
			stream.on_finish = nil
		end
	)
end

-- ── Non‑streaming request dispatcher ─────────────────────────────────────────

--- Send a blocking completion request using the active backend.
---
--- The callback receives `(text, nil)` on success, or `(nil, err_msg)` on failure.
---@param prefix   string
---@param suffix   string
---@param callback fun(string?, string?)
function M.request_completion(prefix, suffix, callback)
	local backend = load_backend()
	local retried = false

	local function do_request(suffix_val)
		backend.request_completion(prefix, suffix_val, function(text, err)
			if err then
				callback(nil, err)
				return
			end

			local cleaned = cleanup_completion(text or "", suffix_val)

			-- Retry with prefix-only if FIM returned empty
			if cleaned == "" and suffix_val ~= "" and not retried then
				retried = true
				local cfg = require("yapper.config").options
				local saved_num = cfg.num_predict
				cfg.num_predict = math.min(saved_num or 64, 16)
				do_request("")
				cfg.num_predict = saved_num
				return
			end

			-- Prefix-only: truncate at first newline
			if suffix_val == "" then
				local nl = cleaned:find("\n")
				if nl then
					cleaned = cleaned:sub(1, nl - 1)
				end
			end

			callback(cleaned)
		end)
	end

	do_request(suffix)
end

return M
