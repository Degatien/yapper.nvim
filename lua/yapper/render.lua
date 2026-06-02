local M = {}

local ns = vim.api.nvim_create_namespace("yapper_ns")

--- Ghost text highlight group. Set up lazily so users can override it.
--- Defaults to a dimmed foreground that blends in without being distracting.
local GHOST_HL = "YapperGhost"

--- Set up the default ghost-text highlight if it doesn't exist yet.
--- If the user has already defined `YapperGhost` in their colorscheme or
--- init.lua, we respect that and don't override it.
local function ensure_highlight()
	local hl = vim.api.nvim_get_hl(0, { name = GHOST_HL })
	-- nvim_get_hl returns {} when the group doesn't exist
	if not hl or vim.tbl_isempty(hl) then
		pcall(vim.api.nvim_set_hl, 0, GHOST_HL, {
			fg = "#6b7280", -- Tailwind gray-500: subtle, not invisible
			italic = true,
		})
	end
end

--- Shared helper: build the virt_text for a single chunk.
---@param text string
---@return table
local function virt_text_entry(text)
	return { { text, GHOST_HL } }
end

local state = {
	extmark_id = nil,
	text = nil,
	-- "overlay" for single‑line, "virt_lines" for multi‑line
	mode = nil,
	loading_id = nil,
}

--- Low‑level: place or update the extmark with ghost-text style rendering.
---
--- For single‑line completions the text is rendered as an inline overlay
--- (ghost text after the cursor).  For multi‑line completions the **first**
--- line is rendered inline and the remaining lines are rendered as virtual
--- lines below — this gives a natural ghost-text feel where the first line
--- flows from the cursor and you can preview what follows.
---
---@param buf  number
---@param row1 number  1‑based row for the extmark
---@param col  number  0‑based column
---@param text string   the completion text
---@param id   integer|nil  existing extmark id to update in place
---@return boolean, integer|nil
local function set_or_update_extmark(buf, row1, col, text, id)
	ensure_highlight()
	local has_newline = text:find("\n")

	if has_newline then
		local lines = vim.split(text, "\n", { plain = true })
		-- First line: inline ghost text after the cursor
		-- Remaining lines: virt_lines below (ghost preview)
		local remaining = {}
		for i = 2, #lines do
			table.insert(remaining, virt_text_entry(lines[i]))
		end
		return pcall(vim.api.nvim_buf_set_extmark, buf, ns, row1, col, {
			id = id,
			virt_text = virt_text_entry(lines[1]),
			virt_text_pos = "overlay",
			virt_lines = remaining,
			virt_lines_above = false,
		})
	else
		return pcall(vim.api.nvim_buf_set_extmark, buf, ns, row1, col, {
			id = id,
			virt_text = virt_text_entry(text),
			virt_text_pos = "overlay",
		})
	end
end

--- Show yapper text after the cursor.
--- Clears any previous yapper first.
---@param text string The completion text to display.
function M.show_yapper(text)
	M.clear_yapper()
	if not text or text == "" then
		return
	end
	local cursor = vim.api.nvim_win_get_cursor(0)
	local row_1 = cursor[1]
	local col = cursor[2]

	local ok, new_id = set_or_update_extmark(0, row_1 - 1, col, text, nil)
	if ok then
		state.extmark_id = new_id
		state.text = text
		state.mode = text:find("\n") and "virt_lines" or "overlay"
	end
end

--- Update the existing yapper text in place (no flicker).
--- The extmark must already exist (created by `show_yapper`).
---@param text string The updated completion text.
function M.update_yapper(text)
	if not state.extmark_id then
		return
	end
	if not text or text == "" then
		M.clear_yapper()
		return
	end
	local cursor = vim.api.nvim_win_get_cursor(0)
	local ok = set_or_update_extmark(0, cursor[1] - 1, cursor[2], text, state.extmark_id)
	if ok then
		state.text = text
		state.mode = text:find("\n") and "virt_lines" or "overlay"
	else
		-- Extmark was invalidated (e.g. buffer changed underneath us)
		M.clear_yapper()
	end
end

--- Remove the current yapper text.
function M.clear_yapper()
	M.hide_loading()
	if state.extmark_id then
		pcall(vim.api.nvim_buf_del_extmark, 0, ns, state.extmark_id)
	end
	state.extmark_id = nil
	state.text = nil
	state.mode = nil
end

--- Show a loading indicator at the cursor while the model is thinking.
--- Clears any existing yapper first.
function M.show_loading()
	M.clear_yapper()
	local cursor = vim.api.nvim_win_get_cursor(0)
	local ok, id = pcall(vim.api.nvim_buf_set_extmark, 0, ns, cursor[1] - 1, cursor[2], {
		virt_text = { { " ⟐", "NonText" } },
		virt_text_pos = "overlay",
	})
	if ok then
		state.loading_id = id
	end
end

--- Hide the loading indicator if visible.
function M.hide_loading()
	if state.loading_id then
		pcall(vim.api.nvim_buf_del_extmark, 0, ns, state.loading_id)
		state.loading_id = nil
	end
end

--- Check whether the loading indicator is currently shown.
---@return boolean
function M.is_loading()
	return state.loading_id ~= nil
end

--- Insert the yapper text into the buffer and clear it.
function M.accept_yapper()
	if not state.text then
		return
	end
	local cursor = vim.api.nvim_win_get_cursor(0)
	local row_1 = cursor[1]
	local col = cursor[2]

	local lines = vim.split(state.text, "\n", { plain = true })
	vim.api.nvim_buf_set_text(0, row_1 - 1, col, row_1 - 1, col, lines)

	if #lines > 1 then
		vim.api.nvim_win_set_cursor(0, { row_1 + #lines - 1, #lines[#lines] })
	else
		vim.api.nvim_win_set_cursor(0, { row_1, col + #state.text })
	end

	M.clear_yapper()
end

--- Check whether a yapper is currently displayed.
---@return boolean
function M.is_visible()
	return state.extmark_id ~= nil
end

return M
