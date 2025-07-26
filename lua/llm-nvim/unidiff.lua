local M = {} ----------------------------------------- public API

----------------------------------------------------------------- helpers
local function splitlines(text)
	local t, i = {}, 1
	for nl in text:gmatch("()\n") do
		table.insert(t, text:sub(i, nl))
		i = nl + 1
	end
	if i <= #text then
		table.insert(t, text:sub(i))
	end
	return t
end

local SequenceMatcher = {}
SequenceMatcher.__index = SequenceMatcher

function SequenceMatcher.new(a, b)
	local self = setmetatable({}, SequenceMatcher)
	self.a = a
	self.b = b
	return self
end

-- Finds the longest contiguous matching block in sub-regions of a and b.
function SequenceMatcher:_find_longest_match(alo, ahi, blo, bhi)
	local best_i, best_j, best_k = alo, blo, 0

	local b2j = {}
	for j = blo, bhi - 1 do
		local item = self.b[j + 1]
		if not b2j[item] then
			b2j[item] = {}
		end
		table.insert(b2j[item], j + 1)
	end

	for i = alo, ahi - 1 do
		local item_a = self.a[i + 1]
		if b2j[item_a] then
			for _, j_b in ipairs(b2j[item_a]) do
				local k = 0
				while i + k < ahi and j_b - 1 + k < bhi and self.a[i + k + 1] == self.b[j_b + k] do
					k = k + 1
				end
				if k > best_k then
					best_i, best_j, best_k = i + 1, j_b, k
				end
			end
		end
	end
	return best_i, best_j, best_k
end

-- Generates opcodes (tag, i1, i2, j1, j2) describing the differences.
function SequenceMatcher:get_opcodes()
	local opcodes = {}
	local stack = { { 1, #self.a + 1, 1, #self.b + 1 } }

	while #stack > 0 do
		local alo, ahi, blo, bhi = unpack(table.remove(stack))
		local best_i, best_j, best_k = self:_find_longest_match(alo - 1, ahi - 1, blo - 1, bhi - 1)

		if best_k > 0 then
			if alo < best_i then
				table.insert(stack, { alo, best_i, blo, best_j })
			end
			if best_i + best_k < ahi then
				table.insert(stack, { best_i + best_k, ahi, best_j + best_k, bhi })
			end
			table.insert(opcodes, { "equal", best_i, best_i + best_k, best_j, best_j + best_k })
		else
			local la, lb = ahi - alo, bhi - blo
			if la > 0 and lb > 0 then
				table.insert(opcodes, { "replace", alo, ahi, blo, bhi })
			elseif la > 0 then
				table.insert(opcodes, { "delete", alo, ahi, blo, bhi })
			elseif lb > 0 then
				table.insert(opcodes, { "insert", alo, ahi, blo, bhi })
			end
		end
	end

	table.sort(opcodes, function(a, b)
		if a[2] ~= b[2] then
			return a[2] < b[2]
		end
		if a[4] ~= b[4] then
			return a[4] < b[4]
		end
		return false
	end)
	return opcodes
end
local function rstrip_newlines(s)
	return s:match("^(.-)\n*$")
end

local Differ = {}
Differ.__index = Differ
function Differ.new(left)
	return setmetatable({ left_lines = left, right_text = "" }, Differ)
end
function Differ:update(tok)
	self.right_text = self.right_text .. tok
	return self:lines()
end

function Differ:lines()
	local right = splitlines(self.right_text)
	local ops = SequenceMatcher.new(self.left_lines, right):get_opcodes()
	local out = {}

	for _, op in ipairs(ops) do
		local tag, i1, i2, j1, j2 = unpack(op)

		if tag == "equal" then
			for i = i1, i2 - 1 do
				table.insert(out, rstrip_newlines("  " .. self.left_lines[i]))
			end
		elseif tag == "delete" then
			for i = i1, i2 - 1 do
				table.insert(out, rstrip_newlines("- " .. self.left_lines[i]))
			end
		elseif tag == "insert" then
			for j = j1, j2 - 1 do
				table.insert(out, rstrip_newlines("+ " .. right[j]))
			end
		else -- replace
			local n1, n2 = i2 - i1, j2 - j1
			for k = 0, math.max(n1, n2) - 1 do
				if k < n1 then
					table.insert(out, rstrip_newlines("- " .. self.left_lines[i1 + k]))
				end
				if k < n2 then
					table.insert(out, rstrip_newlines("+ " .. right[j1 + k]))
				end
			end
		end
	end
	return out
end

M.Differ = Differ
return M
