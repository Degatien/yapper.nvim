--- ghost.nvim — inline completion plugin.
--- Spawn a ghost: `:GhostComplete`, or let it auto‑trigger.
--- See README.md for setup and keymaps.

local M = {}

function M.setup(opts)
	require("ghost.config").setup(opts)

	local completion = require("ghost.completion")
	local render = require("ghost.render")
	local config = require("ghost.config").options

	--- Manual completion command.
	vim.api.nvim_create_user_command("GhostComplete", function()
		if not config.enabled then
			return
		end
		local prefix, suffix = completion.get_context()
		local prompt = completion.build_prompt(prefix, suffix)
		completion.request_completion(prompt, function(text, err)
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

	-- Clear ghost on any text change (auto‑dismiss when typing past suggestion)
	-- TODO: re‑trigger after debounce instead of just clearing
	vim.api.nvim_create_autocmd("InsertCharPre", {
		group = vim.api.nvim_create_augroup("ghost_nvim", { clear = true }),
		callback = function()
			render.clear_ghost()
		end,
	})
end

return M
