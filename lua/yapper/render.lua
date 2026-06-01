local M = {}

local ns = vim.api.nvim_create_namespace("yapper_ns")

local state = {
	extmark_id = nil,
	text = nil,
	-- "overlay" for single‑line, "virt_lines" for multi‑line
	mode = nil,
	loading_id = nil,
}

--- Low‑level: place or update the extmark.
--- Switches between `virt_text` (single‑line) and `virt_lines` (multi‑line)
--- automatically so multi‑line completions display correctly.
local function set_or_update_extmark(buf, row_1, col, text, id)
	local has_newline = text:find("\n")

	if has_newline then
		local lines = vim.split(text, "\n", { plain = true })
		local virt_lines = {}
		for _, l in ipairs(lines) do
			table.insert(virt_lines, { { l, "Comment" } })
		end
		return pcall(vim.api.nvim_buf_set_extmark, buf, ns, row_1, col, {
			id = id,
			virt_lines = virt_lines,
			virt_lines_above = false,
		})
	else
		return pcall(vim.api.nvim_buf_set_extmark, buf, ns, row_1, col, {
			id = id,
			virt_text = { { text, "Comment" } },
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
