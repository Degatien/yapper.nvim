--- Smart context gathering for ghost.nvim.
---
--- Collects prefix and suffix for completions, inspired by how Copilot
--- selects context:
---   1. Import region (top of file before first definition)
---   2. All enclosing structural definitions (module → struct → impl → method)
---   3. Recent lines near the cursor

local M = {}

-- ── Tree-sitter helpers ──────────────────────────────────────────────────────

--- Node types that count as function / class / struct / method / interface / enum definitions.
--- Covers a wide range of languages (Go, Rust, TypeScript, Python, Java, Elixir, etc.).
local STRUCTURAL_NODES = {
	-- Functions / methods
	function_declaration = true,
	function_definition = true,
	method_declaration = true,
	method_definition = true,
	arrow_function = true,
	-- Classes
	class_declaration = true,
	class_definition = true,
	class_body = true,
	-- Interfaces / protocols / traits
	interface_declaration = true,
	interface_definition = true,
	protocol_declaration = true,
	protocol_definition = true,
	trait_definition = true,
	trait_impl = true,
	impl_definition = true,
	-- Structs / records
	struct_specification = true,
	struct_definition = true,
	record_declaration = true,
	record_definition = true,
	-- Enums
	enum_declaration = true,
	enum_definition = true,
	enum_body = true,
	enum_variant_list = true,
	-- Type aliases / definitions
	type_definition = true,
	type_alias = true,
	type_declaration = true,
	-- Modules / namespaces
	module_definition = true,
	module_declaration = true,
}

--- Find ALL enclosing structural nodes (ancestor chain) at a given 0‑based row.
--- Returns outermost first, innermost last.
--- e.g. for a method inside a struct inside a module: {module, struct, method}
---@param buf number
---@param row0 number  0‑based row
---@return table[]|nil   list of tree‑sitter nodes (outermost → innermost)
local function find_enclosing_nodes(buf, row0)
	local ok, parser = pcall(vim.treesitter.get_parser, buf)
	if not ok or not parser then
		return nil
	end
	local tree = parser:parse()[1]
	if not tree then
		return nil
	end

	local ancestors = {}

	local function walk(node)
		if not node then
			return
		end
		local s_row, _, e_row, _ = node:range()
		-- Node must contain the cursor row
		if s_row > row0 or e_row < row0 then
			return
		end
		if STRUCTURAL_NODES[node:type()] then
			table.insert(ancestors, node)
		end
		-- Walk children; only descend into children that contain the cursor
		for child in node:iter_children() do
			local cs, _, ce, _ = child:range()
			if cs <= row0 and ce >= row0 then
				walk(child)
			end
		end
	end

	walk(tree:root())
	return #ancestors > 0 and ancestors or nil
end

--- Guess where the first definition starts (for import‑region detection).
--- Only considers top-level nodes to avoid nested functions.
--- Falls back to nil if tree‑sitter is unavailable.
---@param buf number
---@return number|nil  0‑based row, or nil
local function first_definition_row(buf)
	local ok, parser = pcall(vim.treesitter.get_parser, buf)
	if not ok or not parser then
		return nil
	end
	local tree = parser:parse()[1]
	if not tree then
		return nil
	end

	-- Only scan top-level children — nested definitions don't define import boundaries.
	for child in tree:root():iter_children() do
		if STRUCTURAL_NODES[child:type()] then
			return child:start() -- first return value is the row
		end
	end
	return nil
end

-- ── Simple context (original behaviour) ──────────────────────────────────────

--- Collect prefix / suffix using a simple line‑window around the cursor.
---@param buf  number
---@param row0 number  0‑based cursor row
---@param col  number  0‑based cursor column
---@param lines string[]
---@return string, string
local function context_simple(buf, row0, col, lines)
	local ctx = require("ghost.config").options.context_window

	local current_line = lines[row0 + 1] or ""
	local before_cursor = current_line:sub(1, col)
	local after_cursor = current_line:sub(col + 1)

	local prefix_start = math.max(0, row0 - ctx.prefix_lines)
	local prefix = {}
	for i = prefix_start, row0 - 1 do
		table.insert(prefix, lines[i + 1] or "")
	end
	table.insert(prefix, before_cursor)

	local suffix = { after_cursor }
	for i = row0 + 2, math.min(#lines, row0 + 1 + ctx.suffix_lines) do
		table.insert(suffix, lines[i] or "")
	end

	return table.concat(prefix, "\n"), table.concat(suffix, "\n")
end

-- ── Smart context (Copilot‑inspired) ─────────────────────────────────────────

--- Collect prefix / suffix with smart selection:
---   1. Import region (top of file before first definition)
---   2. All enclosing structural definitions (outermost → innermost)
---   3. Recent lines before cursor
---
--- Lines are deduplicated and presented in file order so the model sees a
--- coherent view of the codebase.
---@param buf  number
---@param row0 number  0‑based cursor row
---@param col  number  0‑based cursor column
---@param lines string[]
---@return string, string
local function context_smart(buf, row0, col, lines)
	local ctx = require("ghost.config").options.context_window

	local current_line = lines[row0 + 1] or ""
	local before_cursor = current_line:sub(1, col)
	local after_cursor = current_line:sub(col + 1)

	-- Track which lines are already included (by 0‑based row)
	local included = {}
	local result = {} -- { {row = int, text = string} }

	-- 1.  Import region: from top of file to just before the first definition.
	--     This captures imports, package declarations, using-statements, etc.
	--     Always include at least 5 lines, at most 30.
	local first_def = first_definition_row(buf)
	local import_end = math.min(math.max(first_def or 30, 5), 30)
	for i = 0, import_end - 1 do
		if i < row0 then
			table.insert(result, { row = i, text = lines[i + 1] or "" })
			included[i] = true
		end
	end

	-- 2.  Enclosing structural definitions (outermost → innermost).
	--     Include the first few lines of each for signature context.
	--     This captures the full chain: module → struct → impl → method, etc.
	local ancestors = find_enclosing_nodes(buf, row0)
	if ancestors then
		for _, node in ipairs(ancestors) do
			local s_row, _, e_row = node:range()
			-- Include up to 4 lines or half the node, whichever is smaller
			local sig_end = math.min(s_row + 4, s_row + math.floor((e_row - s_row) / 2), row0 - 1)
			for i = s_row, sig_end do
				if not included[i] then
					table.insert(result, { row = i, text = lines[i + 1] or "" })
					included[i] = true
				end
			end
		end
	end

	-- 3.  Recent lines before cursor (up to prefix_lines).
	local prefix_start = math.max(0, row0 - ctx.prefix_lines)
	for i = prefix_start, row0 - 1 do
		if not included[i] then
			table.insert(result, { row = i, text = lines[i + 1] or "" })
		end
	end

	-- Sort by line number so the prompt is in file order
	table.sort(result, function(a, b)
		return a.row < b.row
	end)

	local prefix_lines = {}
	for _, item in ipairs(result) do
		table.insert(prefix_lines, item.text)
	end

	-- 4.  LSP enrichment (opt‑in): look up type definitions across the project.
	if ctx.lsp_enrich then
		local ok, context_lsp = pcall(require, "ghost.context_lsp")
		if ok then
			local extra = context_lsp.enrich(prefix_lines, ctx.lsp_max_types or 3)
			if extra and #extra > 0 then
				-- Prepend LSP definitions before the rest of the context
				for _, line in ipairs(extra) do
					table.insert(prefix_lines, 1, line)
				end
			end
		end
	end

	table.insert(prefix_lines, before_cursor)

	-- Suffix: lines below cursor (always contiguous, simpler)
	local suffix = { after_cursor }
	for i = row0 + 2, math.min(#lines, row0 + 1 + ctx.suffix_lines) do
		table.insert(suffix, lines[i] or "")
	end

	return table.concat(prefix_lines, "\n"), table.concat(suffix, "\n")
end

-- ── Public API ───────────────────────────────────────────────────────────────

--- Collect prefix and suffix for the current cursor position.
---
--- Uses the strategy configured in `context_window.strategy`:
---   "simple" — contiguous line window (original behaviour)
---   "smart"  — imports + function signature + recent lines (Copilot‑inspired)
---
---@return string prefix, string suffix
function M.get_context()
	local config = require("ghost.config").options
	local buf = vim.api.nvim_get_current_buf()
	local cursor = vim.api.nvim_win_get_cursor(0)
	local row0 = cursor[1] - 1 -- 0‑based
	local col = cursor[2]

	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

	local strategy = config.context_window.strategy or "smart"
	if strategy == "simple" then
		return context_simple(buf, row0, col, lines)
	end
	return context_smart(buf, row0, col, lines)
end

return M
