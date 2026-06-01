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
	local config = require("ghost.config").options
	local ok, backend = pcall(require, "ghost.backend." .. config.backend)
	if not ok then
		error("ghost.nvim: unknown backend '" .. config.backend .. "'")
	end
	return backend
end

-- ── Context ───────────────────────────────────────────────────────────────────

--- Collect prefix and suffix for the current cursor position.
--- Delegates to `ghost.context` which implements the configured strategy.
---@return string prefix, string suffix
function M.get_context()
	return require("ghost.context").get_context()
end

-- ── Comment wrapping ─────────────────────────────────────────────────────────

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

--- Clean up whitespace from the model's output and truncate if the
--- completion starts regenerating code already present in the suffix.
---@param text   string   the raw completion from the model
---@param suffix string   code after the cursor (used for overlap detection)
---@return string
local function cleanup_completion(text, suffix)
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

	-- Wrap comment lines at 80 characters
	text = wrap_comment_lines(text, 80)

	-- Strip any lines starting with NOTE: — the model uses this tag when it
	-- must include a non-code note (per the system prompt).
	text = text:gsub("^NOTE:[^\n]*\n?", "")
	text = text:gsub("\nNOTE:[^\n]*", "")

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
			else
				local cleaned = cleanup_completion(text or "", suffix)
				if stream.on_finish then
					stream.on_finish(cleaned)
				end
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

	backend.request_completion(prefix, suffix, function(text, err)
		if err then
			callback(nil, err)
		else
			callback(cleanup_completion(text or "", suffix))
		end
	end)
end

return M
