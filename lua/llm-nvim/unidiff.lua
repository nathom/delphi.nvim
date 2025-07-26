local ns = vim.api.nvim_create_namespace("unidiff_ns")
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

----------------------------------------------------------------- SequenceMatcher (minimal)
local Seq = {}
Seq.__index = Seq
function Seq.new(a, b)
	return setmetatable({ a = a, b = b }, Seq)
end
function Seq:_find(alo, ahi, blo, bhi)
	local best_i, best_j, best_k = alo, blo, 0
	local b2j = {}
	for j = blo, bhi - 1 do
		local s = self.b[j + 1]
		b2j[s] = b2j[s] or {}
		table.insert(b2j[s], j + 1)
	end
	for i = alo, ahi - 1 do
		for _, j in ipairs(b2j[self.a[i + 1]] or {}) do
			local k = 0
			while i + k < ahi and j - 1 + k < bhi and self.a[i + k + 1] == self.b[j + k] do
				k = k + 1
			end
			if k > best_k then
				best_i, best_j, best_k = i + 1, j, k
			end
		end
	end
	return best_i, best_j, best_k
end
function Seq:get()
	local st, ops = { { 1, #self.a + 1, 1, #self.b + 1 } }, {}
	while #st > 0 do
		local alo, ahi, blo, bhi = unpack(table.remove(st))
		local i, j, k = self:_find(alo - 1, ahi - 1, blo - 1, bhi - 1)
		if k > 0 then
			if alo < i then
				table.insert(st, { alo, i, blo, j })
			end
			if i + k < ahi then
				table.insert(st, { i + k, ahi, j + k, bhi })
			end
			table.insert(ops, { "equal", i, i + k, j, j + k })
		else
			local la, lb = ahi - alo, bhi - blo
			local tag = (la > 0 and lb > 0) and "replace" or (la > 0) and "delete" or "insert"
			table.insert(ops, { tag, alo, ahi, blo, bhi })
		end
	end
	table.sort(ops, function(a, b)
		return a[2] < b[2] or (a[2] == b[2] and a[4] < b[4])
	end)
	return ops
end

local function rstrip_newlines(s)
	local new_s, _ = s:gsub("[\r\n]+$", "")
	return new_s
end
----------------------------------------------------------------- Incremental differ
local Differ = {}
Differ.__index = Differ
function Differ.new(left)
	return setmetatable({ left_lines = splitlines(left), right_text = "" }, Differ)
end
function Differ:update(tok)
	self.right_text = self.right_text .. tok
	return self:lines()
end
function Differ:lines()
	local right = splitlines(self.right_text)
	local ops = Seq.new(self.left_lines, right):get()
	local out = {}
	for _, op in ipairs(ops) do
		local tag, i1, i2, j1, j2 = unpack(op)
		local line
		if tag == "equal" then
			for i = i1, i2 - 1 do
				line = "  " .. self.left_lines[i]
			end
		elseif tag == "delete" then
			for i = i1, i2 - 1 do
				line = "- " .. self.left_lines[i]
			end
		elseif tag == "insert" then
			for j = j1, j2 - 1 do
				line = "+ " .. right[j]
			end
		else -- replace
			local n1, n2 = i2 - i1, j2 - j1
			for k = 0, math.max(n1, n2) - 1 do
				if k < n1 then
					line = "- " .. self.left_lines[i1 + k]
				end
				if k < n2 then
					line = "+ " .. right[j1 + k]
				end
			end
		end
		table.insert(out, rstrip_newlines(line))
	end
	return out
end

M.Differ = Differ
return M
