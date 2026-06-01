--- ghost.nvim — inline completion plugin.
--- Spawn a ghost: `:GhostComplete`, or let it auto‑trigger.
--- See README.md for setup and keymaps.

local M = {}

function M.setup(opts)
	require("ghost.config").setup(opts)

	local completion = require("ghost.completion")
	local render = require("ghost.render")
	local config = require("ghost.config").options

	-- ── Buffer guard ────────────────────────────────────────────────
	--- Skip completions in plugin / special buffers (Telescope, quickfix, terminals,
	--- help, neo‑tree rename, …).  Only normal file buffers have an empty `buftype`.
	---@return boolean
	local function is_code_buffer()
		return vim.bo.buftype == ""
	end

	-- ── Debounce timer & stale‑request guard ───────────────────────
	--- Timer restarted on every keystroke; fires `debounce_ms` after the last one.
	local debounce_timer = vim.uv.new_timer()
	--- Monotonically increasing request ID.  Responses with an old ID are dropped.
	local req_id = 0

	local function trigger_completion()
		if not config.enabled then
			return
		end
		if not is_code_buffer() then
			return
		end
		if vim.api.nvim_get_mode().mode ~= "i" then
			return
		end

		req_id = req_id + 1
		local my_id = req_id

		local prefix, suffix = completion.get_context()

		completion.request_completion_stream(
			prefix,
			suffix,
			---@param text_so_far string
			function(text_so_far)
				-- Only render if this stream is still the active one.
				if my_id ~= req_id then
					return
				end
				-- On the first chunk we create the extmark; on subsequent chunks
				-- we update it in place (no flicker).
				if not render.is_visible() then
					render.show_ghost(text_so_far)
				else
					render.update_ghost(text_so_far)
				end
			end,
			---@param text string?
			---@param err  string?
			function(text, err)
				if my_id ~= req_id then
					return
				end
				if err then
					-- Silently ignore errors during auto‑trigger.
					return
				end
				-- Ensure the final text is shown (the last chunk already did this,
				-- but guard against a race where the stream ends without a final chunk).
				if text and text ~= "" then
					if not render.is_visible() then
						render.show_ghost(text)
					end
				end
			end
		)
	end

	-- ── Autocmd group ──────────────────────────────────────────────

	local ghost_group = vim.api.nvim_create_augroup("ghost_nvim", { clear = true })

	--- Clear ghost the instant the user presses any key (before the char is inserted).
	--- Also cancels any in‑flight stream.
	vim.api.nvim_create_autocmd("InsertCharPre", {
		group = ghost_group,
		callback = function()
			render.clear_ghost()
			completion.cancel_stream()
		end,
	})

	--- After the buffer changed, cancel any in‑flight stream and restart the
	--- debounce timer.  When typing stops for `debounce_ms`, a completion fires.
	vim.api.nvim_create_autocmd("TextChangedI", {
		group = ghost_group,
		callback = function()
			if not config.enabled or not is_code_buffer() then
				return
			end
			completion.cancel_stream()
			debounce_timer:stop()
			debounce_timer:start(
				config.debounce_ms,
				0,
				vim.schedule_wrap(trigger_completion)
			)
		end,
	})

	--- Leaving insert mode cancels any pending request, stream, and ghost.
	vim.api.nvim_create_autocmd("InsertLeave", {
		group = ghost_group,
		callback = function()
			debounce_timer:stop()
			completion.cancel_stream()
			render.clear_ghost()
		end,
	})

	-- ── Commands ───────────────────────────────────────────────────

	--- Manual completion command (non‑streaming, shows errors).
	vim.api.nvim_create_user_command("GhostComplete", function()
		if not config.enabled or not is_code_buffer() then
			return
		end
		local prefix, suffix = completion.get_context()
		completion.request_completion(prefix, suffix, function(text, err)
			if err then
				vim.notify("[ghost] " .. err, vim.log.levels.WARN)
				return
			end
			render.show_ghost(text)
		end)
	end, { desc = "Request a ghost completion" })

	--- Toggle auto‑trigger on/off.
	vim.api.nvim_create_user_command("GhostToggle", function()
		config.enabled = not config.enabled
		if not config.enabled then
			debounce_timer:stop()
			completion.cancel_stream()
			render.clear_ghost()
		end
		vim.notify("[ghost] " .. (config.enabled and "enabled" or "disabled"))
	end, { desc = "Toggle ghost auto‑completion" })

	-- ── Keymaps ─────────────────────────────────────────────────────

	local km = config.keymaps

	-- Manual completion from insert mode
	vim.keymap.set("i", km.manual, function()
		vim.cmd("GhostComplete")
	end, { desc = "Request ghost completion" })

	-- Accept: inserts the ghost text when present, otherwise passes through.
	vim.keymap.set("i", km.accept, function()
		if render.is_visible() then
			render.accept_ghost()
		else
			vim.api.nvim_feedkeys(
				vim.api.nvim_replace_termcodes("<Tab>", true, false, true),
				"n",
				false
			)
		end
	end, { desc = "Accept ghost or Tab" })

	-- Dismiss: clears ghost text, then exits insert mode.
	vim.keymap.set("i", km.dismiss, function()
		if render.is_visible() then
			render.clear_ghost()
		end
		vim.api.nvim_feedkeys(
			vim.api.nvim_replace_termcodes("<Esc>", true, false, true),
			"n",
			false
		)
	end, { desc = "Dismiss ghost or Esc" })

	-- Toggle from normal mode
	vim.keymap.set("n", km.toggle, function()
		vim.cmd("GhostToggle")
	end, { desc = "Toggle ghost auto‑completion" })
end

return M
