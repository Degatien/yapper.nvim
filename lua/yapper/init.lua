--- yapper.nvim — inline completion plugin.
--- Spawn a yapper: `:YapperComplete`, or let it auto‑trigger.
--- See README.md for setup and keymaps.

local M = {}

function M.setup(opts)
	require("yapper.config").setup(opts)

	local completion = require("yapper.completion")
	local render = require("yapper.render")
	local config = require("yapper.config").options

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

		render.show_loading()

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
					render.show_yapper(text_so_far)
				else
					render.update_yapper(text_so_far)
				end
			end,
			---@param text string?
			---@param err  string?
			function(text, err)
				if my_id ~= req_id then
					return
				end
				if err then
					render.hide_loading()
					vim.notify("[yapper] " .. err:gsub("\n.*", ""), vim.log.levels.WARN)
					return
				end
				-- Ensure the final text is shown (the last chunk already did this,
				-- but guard against a race where the stream ends without a final chunk).
				if text and text ~= "" then
					if not render.is_visible() then
						render.show_yapper(text)
					end
				else
					render.hide_loading()
				end
			end
		)
	end

	-- ── Autocmd group ──────────────────────────────────────────────

	local yapper_group = vim.api.nvim_create_augroup("yapper_nvim", { clear = true })

	--- Clear yapper the instant the user presses any key (before the char is inserted).
	--- Also cancels any in‑flight stream.
	vim.api.nvim_create_autocmd("InsertCharPre", {
		group = yapper_group,
		callback = function()
			render.clear_yapper()
			completion.cancel_stream()
		end,
	})

	--- After the buffer changed, cancel any in‑flight stream and restart the
	--- debounce timer.  When typing stops for `debounce_ms`, a completion fires.
	vim.api.nvim_create_autocmd("TextChangedI", {
		group = yapper_group,
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

	--- Leaving insert mode cancels any pending request, stream, and yapper.
	vim.api.nvim_create_autocmd("InsertLeave", {
		group = yapper_group,
		callback = function()
			debounce_timer:stop()
			completion.cancel_stream()
			render.clear_yapper()
		end,
	})

	-- ── Commands ───────────────────────────────────────────────────

	--- Manual completion command (non‑streaming, shows errors).
	vim.api.nvim_create_user_command("YapperComplete", function()
		if not config.enabled or not is_code_buffer() then
			return
		end
		local prefix, suffix = completion.get_context()
		render.show_loading()
		completion.request_completion(prefix, suffix, function(text, err)
			render.hide_loading()
			if err then
				-- Truncate long error messages at the first newline
				local msg = err:gsub("\n.*", "")
				vim.notify("[yapper] " .. msg, vim.log.levels.WARN)
				return
			end
			render.show_yapper(text)
		end)
	end, { desc = "Request a yapper completion" })

	--- Toggle auto‑trigger on/off.
	vim.api.nvim_create_user_command("YapperToggle", function()
		config.enabled = not config.enabled
		if not config.enabled then
			debounce_timer:stop()
			completion.cancel_stream()
			render.clear_yapper()
		end
		vim.notify("[yapper] " .. (config.enabled and "enabled" or "disabled"))
	end, { desc = "Toggle yapper auto‑completion" })

	-- ── Keymaps ─────────────────────────────────────────────────────

	local km = config.keymaps

	-- Manual completion from insert mode
	vim.keymap.set("i", km.manual, function()
		vim.cmd("YapperComplete")
	end, { desc = "Request yapper completion" })

	-- Accept: inserts the yapper text when present, otherwise passes through.
	vim.keymap.set("i", km.accept, function()
		if render.is_visible() then
			render.accept_yapper()
		else
			vim.api.nvim_feedkeys(
				vim.api.nvim_replace_termcodes("<Tab>", true, false, true),
				"n",
				false
			)
		end
	end, { desc = "Accept yapper or Tab" })

	-- Dismiss: clears yapper text, then exits insert mode.
	vim.keymap.set("i", km.dismiss, function()
		if render.is_visible() then
			render.clear_yapper()
		end
		vim.api.nvim_feedkeys(
			vim.api.nvim_replace_termcodes("<Esc>", true, false, true),
			"n",
			false
		)
	end, { desc = "Dismiss yapper or Esc" })

	-- Toggle from normal mode
	vim.keymap.set("n", km.toggle, function()
		vim.cmd("YapperToggle")
	end, { desc = "Toggle yapper auto‑completion" })
end

return M
