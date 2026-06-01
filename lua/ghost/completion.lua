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

-- ── Response cleanup ─────────────────────────────────────────────────────────

--- Clean up whitespace from the model's output.
---@param text string
---@return string
local function cleanup_completion(text)
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
				local cleaned = cleanup_completion(text or "")
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
			callback(cleanup_completion(text or ""))
		end
	end)
end

return M
