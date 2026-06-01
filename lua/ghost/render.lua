local M = {}

local ns = vim.api.nvim_create_namespace("ghost_ns")

local state = {
	extmark_id = nil,
	text = nil,
}

--- Show ghost text after the cursor.
---@param text string The completion text to display.
function M.show_ghost(text)
	M.clear_ghost()
	if not text or text == "" then
		return
	end
	local cursor = vim.api.nvim_win_get_cursor(0)
	local row_1 = cursor[1]
	local col = cursor[2]

	local ok, id = pcall(vim.api.nvim_buf_set_extmark, 0, ns, row_1 - 1, col, {
		virt_text = { { text, "Comment" } },
		virt_text_pos = "overlay",
	})
	if ok then
		state.extmark_id = id
		state.text = text
	end
end

--- Remove the current ghost text.
function M.clear_ghost()
	if state.extmark_id then
		pcall(vim.api.nvim_buf_del_extmark, 0, ns, state.extmark_id)
	end
	state.extmark_id = nil
	state.text = nil
end

--- Insert the ghost text into the buffer and clear it.
function M.accept_ghost()
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

	M.clear_ghost()
end

--- Check whether a ghost is currently displayed.
---@return boolean
function M.is_visible()
	return state.extmark_id ~= nil
end

return M
