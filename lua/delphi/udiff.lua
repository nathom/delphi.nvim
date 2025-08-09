---@class Udiff
---@field _ base_lines string[]
---@field _patch string
---@field _hunks table[]|nil
local U = {}
U.__index = U

---Create a new udiff applier bound to a specific base file.
---@param base_lines string[]
---@return Udiff
function U.new(base_lines)
	local o = { _ = base_lines, _patch = "", _hunks = nil }
	return setmetatable(o, U)
end

---Append more diff text (streamed) to the internal buffer.
---@param chunk string
function U:push(chunk)
	if type(chunk) == "string" and #chunk > 0 then
		self._patch = self._patch .. chunk
		print(self._patch)
	end
end

---Split a string into lines without dropping a final partial line.
---@param s string
---@return string[]
local function split_lines_keep_partial(s)
	local t = {}
	local start = 1
	while true do
		local i, j = string.find(s, "\n", start, true)
		if not i then
			table.insert(t, string.sub(s, start))
			break
		end
		table.insert(t, string.sub(s, start, i - 1))
		start = j + 1
	end
	return t
end

-- Parse complete hunks from current patch text.
-- Returns array of hunks: { a_start: int, items: { {tag:' '|'-'|'+' , text:string}... } }
-- Stops before an incomplete or malformed hunk.
---@return table[] hunks|nil
function U:_parse_hunks()
	local lines = split_lines_keep_partial(self._patch)
	local i = 1
	local hunks = {}

	local function starts_with(str, prefix)
		return string.sub(str, 1, #prefix) == prefix
	end

    local function trim_prefix(line)
        local first = string.sub(line, 1, 1)
        if first ~= " " and first ~= "+" and first ~= "-" then
            return nil, line
        end
        local rest = string.sub(line, 2)
        return first, rest
    end

	while i <= #lines do
		local l = lines[i]
		if starts_with(l, "@@") then
			local a_start = string.match(l, "^@@%s*%-(%d+),?%d*%s+%+%d+,?%d*%s*@@")
			if not a_start then
				break
			end
			local hunk = { a_start = tonumber(a_start), items = {} }
			i = i + 1
			while i <= #lines do
				local body = lines[i]
				if starts_with(body, "@@") then
					break
				end
				if
					starts_with(body, "diff ")
					or starts_with(body, "index ")
					or starts_with(body, "--- ")
					or starts_with(body, "+++ ")
				then
					i = i + 1
				else
					local tag, text = trim_prefix(body)
					if tag == nil then
						-- End of available input or non-hunk text: finalize current hunk
						table.insert(hunks, hunk)
						return hunks
					end
					table.insert(hunk.items, { tag = tag, text = text })
					i = i + 1
				end
			end
			table.insert(hunks, hunk)
		-- do not increment i here; outer loop checks current line for next header
		else
			i = i + 1
		end
	end

	if #hunks == 0 then
		return nil
	end
	return hunks
end

---@param hunks table[]
---@return string[] patched
local function apply_hunks_to_base(base, hunks)
	local out = {}
	local cursor = 1
	for _, h in ipairs(hunks) do
		local a_start = h.a_start or 1
		while cursor < a_start and cursor <= #base do
			table.insert(out, base[cursor])
			cursor = cursor + 1
		end
		for _, item in ipairs(h.items) do
			if item.tag == " " then
				if cursor <= #base then
					table.insert(out, base[cursor])
				else
					table.insert(out, item.text)
				end
				cursor = cursor + 1
			elseif item.tag == "-" then
				cursor = cursor + 1
			elseif item.tag == "+" then
				table.insert(out, item.text)
			end
		end
	end
	while cursor <= #base do
		table.insert(out, base[cursor])
		cursor = cursor + 1
	end
	return out
end

---Compute overlay operations from parsed hunks.
---@return table[] ops  -- { {kind='del'|'add', row:int, text:string}, ...}
function U:overlay_ops()
	local hunks = self._hunks
	if not hunks then
		return {}
	end
	local ops = {}
	for _, h in ipairs(hunks) do
		local row = (h.a_start or 1) - 1 -- 0-based cursor in base
		for _, it in ipairs(h.items) do
			if it.tag == " " then
				row = row + 1
			elseif it.tag == "-" then
				table.insert(ops, { kind = "del", row = row, text = it.text })
				row = row + 1
			elseif it.tag == "+" then
				-- Anchor additions at current row; virt_lines_above will display before this row
				table.insert(ops, { kind = "add", row = row, text = it.text })
			end
		end
	end
	return ops
end

---Try to apply as many complete hunks as possible from the current patch.
---Returns best-effort patched lines or nil if no hunks parsed yet.
---@return string[]|nil
function U:apply_partial()
	local hunks = self:_parse_hunks()
	if not hunks then
		return nil
	end
	self._hunks = hunks
	return apply_hunks_to_base(self._, hunks)
end

return { new = U.new }
