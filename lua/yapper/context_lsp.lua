--- LSP-powered context enrichment for yapper.nvim.
---
--- Extracts type names from the enclosing function signatures and nearby
--- code, then looks up their definitions across the workspace via LSP.
--- The resolved definitions are included in the completion prompt so the
--- model understands the types it's working with — even across files.
---
--- Falls back gracefully if no LSP client is attached or lookups time out.

local M = {}

-- ── Simple cache ──────────────────────────────────────────────────────────────

--- Cache: "filepath:type_name" → { lines = string[], ts = number }
local _cache = {}
local CACHE_TTL_MS = 30000

-- ── Type-name extraction ─────────────────────────────────────────────────────

--- Words commonly confused as type names.
local SKIP_WORDS = {
	Get = true, Set = true, New = true, Make = true, Error = true,
	String = true, Int = true, Float = true, Bool = true, Byte = true,
	Rune = true, Len = true, Cap = true, Copy = true, Append = true,
	True = true, False = true, Nil = true, None = true, Some = true,
	Ok = true, Err = true, ToString = true, Format = true, Println = true,
	Printf = true, Sprintf = true,
}

--- Extract likely type names from a chunk of source code.
--- Looks for capitalized words near type-annotation markers.
---@param text string
---@return string[]
function M.extract_type_names(text)
	local seen = {}
	local names = {}

	-- Pattern 1: words after `: `, `(:`, `):` — common in TS, Rust, Go, etc.
	for name in text:gmatch("[:%s(,]([A-Z][a-zA-Z0-9_]+)") do
		if not seen[name] and not SKIP_WORDS[name] then
			seen[name] = true
			table.insert(names, name)
		end
	end

	-- Pattern 2: words inside angle brackets — generics: `Type<Foo>`
	for name in text:gmatch("<([A-Z][a-zA-Z0-9_]+)") do
		if not seen[name] and not SKIP_WORDS[name] then
			seen[name] = true
			table.insert(names, name)
		end
	end

	-- Pattern 3: words after a space at the start of a line or after
	--            `func ` / `fn ` / `def ` — return types
	for name in text:gmatch("func%s+[A-Za-z_]+%s*%([^)]*%)%s*([A-Z][a-zA-Z0-9_]+)") do
		if not seen[name] and not SKIP_WORDS[name] then
			seen[name] = true
			table.insert(names, name)
		end
	end

	return names
end

-- ── LSP helpers ──────────────────────────────────────────────────────────────

local SymbolKind = {
	File = 1, Module = 2, Namespace = 3, Package = 4, Class = 5,
	Method = 6, Property = 7, Field = 8, Constructor = 9, Enum = 10,
	Interface = 11, Function = 12, Variable = 13, Constant = 14,
	String = 15, Number = 16, Boolean = 17, Array = 18, Object = 19,
	Key = 20, Null = 21, EnumMember = 22, Struct = 23, Event = 24,
	Operator = 25, TypeParameter = 26,
}

--- Symbol kinds that represent type/struct/interface definitions.
local TYPE_KINDS = {
	[SymbolKind.Class] = true,
	[SymbolKind.Interface] = true,
	[SymbolKind.Struct] = true,
	[SymbolKind.Enum] = true,
	[SymbolKind.TypeParameter] = true,
	[SymbolKind.Module] = true,
	[SymbolKind.Namespace] = true,
}

--- Check whether a symbol kind is a type definition.
---@param kind integer
---@return boolean
local function is_type_kind(kind)
	return TYPE_KINDS[kind] or false
end

--- Read the relevant lines from a definition location.
--- Uses the symbol's range to extract just the structural node lines.
---@param filepath string
---@param range    { start: { line: number, character: number }, ["end"]?: { line: number, character: number } }
---@return { lines: string[], filepath: string }|nil
local function read_definition(filepath, range)
	if not filepath or vim.fn.filereadable(filepath) == 0 then
		return nil
	end
	local lines = vim.fn.readfile(filepath)
	if #lines == 0 then
		return nil
	end

	local start_line = math.max(0, (range.start.line or 0) - 1)
	-- If we have an end range, use it; otherwise grab 15 lines
	local end_line
	if range["end"] then
		end_line = math.min(#lines, range["end"].line + 1)
	else
		end_line = math.min(#lines, start_line + 15)
	end

	local snippet = {}
	for i = start_line + 1, end_line do
		table.insert(snippet, lines[i])
	end
	return { lines = snippet, filepath = filepath }
end

--- Fetch a type definition from the workspace via LSP.
---@param type_name string
---@param bufnr     number
---@return { lines: string[], filepath: string }|nil
function M.fetch_type_definition(type_name, bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()

	-- Check cache first
	local now = vim.loop.now()
	local cache_key = tostring(bufnr) .. ":" .. type_name
	local cached = _cache[cache_key]
	if cached and (now - cached.ts) < CACHE_TTL_MS then
		return cached.data
	end

	-- Check if any LSP client is attached
	local clients = vim.lsp.get_clients({ bufnr = bufnr })
	if #clients == 0 then
		return nil
	end

	-- For `workspace/symbol`, use the first client that supports it
	local results, err = pcall(vim.lsp.buf_request_sync, bufnr, "workspace/symbol", {
		query = type_name,
	}, 300) -- 300ms timeout

	if not results or err then
		return nil
	end

	local best_match = nil

	-- Iterate over client responses
	for _, response in pairs(results) do
		if response and response.result then
			for _, symbol in ipairs(response.result) do
				-- Prefer exact name match + type kind + different file
				if symbol.name == type_name and is_type_kind(symbol.kind) then
					local filepath = vim.uri_to_fname(symbol.location.uri)
					if filepath ~= vim.api.nvim_buf_get_name(bufnr) then
						-- Prefer this over same-file definitions
						best_match = {
							filepath = filepath,
							range = symbol.location.range,
						}
						break
					elseif not best_match then
						best_match = {
							filepath = filepath,
							range = symbol.location.range,
						}
					end
				end
			end
			if best_match and best_match.filepath ~= vim.api.nvim_buf_get_name(bufnr) then
				break
			end
		end
	end

	if not best_match then
		return nil
	end

	local data = read_definition(best_match.filepath, best_match.range)

	-- Cache the result (even nil, to avoid repeated lookups)
	_cache[cache_key] = { data = data, ts = now }

	return data
end

-- ── Public entry-point ────────────────────────────────────────────────────────

--- Enrich the current prefix with LSP-resolved type definitions from the project.
---
--- @param prefix_lines string[]  lines already collected for the prefix
--- @param max_types    integer   max type definitions to fetch (default 3)
--- @return string[] additional context lines to prepend
function M.enrich(prefix_lines, max_types)
	max_types = max_types or 3
	local bufnr = vim.api.nvim_get_current_buf()
	local seen_types = {}
	local extra_lines = {}

	-- Extract all type names from the existing prefix
	for _, line in ipairs(prefix_lines) do
		local names = M.extract_type_names(line)
		for _, name in ipairs(names) do
			seen_types[name] = true
		end
	end

	-- Fetch definitions for each unique type name (up to max_types)
	local fetched = 0
	for type_name in pairs(seen_types) do
		if fetched >= max_types then
			break
		end
		local def = M.fetch_type_definition(type_name, bufnr)
		if def and def.lines and #def.lines > 0 then
			table.insert(extra_lines, "")
			table.insert(extra_lines, "--- definition of " .. type_name .. " (from " .. def.filepath .. ") ---")
			for _, l in ipairs(def.lines) do
				table.insert(extra_lines, l)
			end
			fetched = fetched + 1
		end
	end

	return extra_lines
end

return M
