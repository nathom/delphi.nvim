local cmp = require("cmp")
local source = {}

function source:is_available()
	return vim.b.is_delphi_chat == true
end

function source:complete(params, callback)
	local line = params.context.cursor_before_line
	local col = params.context.cursor.col
	local prefix = line:sub(1, col)
	local at = prefix:match("@(%S*)$")
	if not at then
		return callback()
	end
	local pat = at .. "*"
	local paths = vim.fn.glob(pat, true, true)
	local items = {}
	for _, p in ipairs(paths) do
		table.insert(items, { label = "@" .. p, insertText = "@" .. p })
	end
	callback({ items = items, isIncomplete = false })
end

return source
