local cmp = require("cmp")

---@class DelphiPathSource
local source = {}

---Only enable this source inside Delphi chat buffers.
---@return boolean
function source:is_available()
	return vim.b.is_delphi_chat == true
end

---Complete @file mentions by globbing paths that match the current token.
---@param params cmp.SourceCompletionApiParams
---@param callback fun(response: cmp.SourceCompletionResponse)
function source:complete(params, callback)
	local line = params.context.cursor_before_line or ""
	local col = params.context.cursor and params.context.cursor.col or #line
	local prefix = line:sub(1, col)

	-- Capture the thing right after '@' up to whitespace
	local at = prefix:match("@(%S*)$")
	if not at then
		return callback()
	end

	local pat = at .. "*"
	---@type string[]
	local paths = vim.fn.glob(pat, true, true)
	local items = {}
	for _, p in ipairs(paths) do
		-- Show and insert with leading '@'
		table.insert(items, { label = "@" .. p, insertText = "@" .. p })
	end
	callback({ items = items, isIncomplete = false })
end

---Ensure typing these characters triggers completion.
---@return string[]
function source:get_trigger_characters()
	return { "@", "/", ".", "-" }
end

return source
