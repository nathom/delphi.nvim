---@class Match
---@field a integer
---@field b integer
---@field size integer

---@class SequenceMatcher
---@field isjunk fun(elm: any):boolean|nil
---@field a any[]
---@field b any[]
---@field autojunk boolean
---@field matching_blocks Match[]|nil
---@field opcodes any[]|nil
---@field b2j table<any, integer[]>
---@field bjunk table<any, boolean>
---@field bpopular table<any, boolean>
---@field fullbcount table<any, integer>|nil

local SequenceMatcher = {}
SequenceMatcher.__index = SequenceMatcher

function SequenceMatcher:new(isjunk, a, b, autojunk)
	local obj = setmetatable({}, SequenceMatcher)
	obj.isjunk = isjunk
	obj.a = nil
	obj.b = nil
	obj.autojunk = autojunk == nil and true or autojunk
	obj:set_seqs(a or {}, b or {})
	return obj
end

function SequenceMatcher:set_seqs(a, b)
	self:set_seq1(a)
	self:set_seq2(b)
end

function SequenceMatcher:set_seq1(a)
	if a == self.a then
		return
	end
	if type(a) == "string" then
		local t = {}
		for i = 1, #a do
			t[i] = string.sub(a, i, i)
		end
		self.a = t
	else
		self.a = a
	end
	self.matching_blocks = nil
	self.opcodes = nil
end

function SequenceMatcher:set_seq2(b)
	if b == self.b then
		return
	end
	if type(b) == "string" then
		local t = {}
		for i = 1, #b do
			t[i] = string.sub(b, i, i)
		end
		self.b = t
	else
		self.b = b
	end
	self.matching_blocks = nil
	self.opcodes = nil
	self.fullbcount = nil
	self:__chain_b()
end

function SequenceMatcher:__chain_b()
	local b = self.b
	self.b2j = {}
	for i, elt in ipairs(b) do
		if self.b2j[elt] == nil then
			self.b2j[elt] = {}
		end
		table.insert(self.b2j[elt], i)
	end

	self.bjunk = {}
	if self.isjunk then
		for elt, _ in pairs(self.b2j) do
			if self.isjunk(elt) then
				self.bjunk[elt] = true
			end
		end
		for elt, _ in pairs(self.bjunk) do
			self.b2j[elt] = nil
		end
	end

	self.bpopular = {}
	local n = #b
	if self.autojunk and n >= 200 then
		local ntest = math.floor(n / 100) + 1
		for elt, idxs in pairs(self.b2j) do
			if #idxs > ntest then
				self.bpopular[elt] = true
			end
		end
		for elt, _ in pairs(self.bpopular) do
			self.b2j[elt] = nil
		end
	end
end

function SequenceMatcher:find_longest_match(alo, ahi, blo, bhi)
	alo = alo or 1
	ahi = ahi or #self.a
	blo = blo or 1
	bhi = bhi or #self.b
	local a, b, b2j = self.a, self.b, self.b2j
	local besti, bestj, bestsize = alo, blo, 0

	local j2len = {}
	local nothing = {}
	for i = alo, ahi do
		local newj2len = {}
		local indices = b2j[a[i]] or nothing
		for _, j in ipairs(indices) do
			if j >= blo and j <= bhi then
				local k = (j2len[j - 1] or 0) + 1
				newj2len[j] = k
				if k > bestsize then
					besti, bestj, bestsize = i - k + 1, j - k + 1, k
				end
			end
		end
		j2len = newj2len
	end

	while besti > alo and bestj > blo and not self.bjunk[b[bestj - 1]] and a[besti - 1] == b[bestj - 1] do
		besti, bestj, bestsize = besti - 1, bestj - 1, bestsize + 1
	end
	while
		besti + bestsize <= ahi
		and bestj + bestsize <= bhi
		and not self.bjunk[b[bestj + bestsize]]
		and a[besti + bestsize] == b[bestj + bestsize]
	do
		bestsize = bestsize + 1
	end

	while besti > alo and bestj > blo and self.bjunk[b[bestj - 1]] and a[besti - 1] == b[bestj - 1] do
		besti, bestj, bestsize = besti - 1, bestj - 1, bestsize + 1
	end
	while
		besti + bestsize <= ahi
		and bestj + bestsize <= bhi
		and self.bjunk[b[bestj + bestsize]]
		and a[besti + bestsize] == b[bestj + bestsize]
	do
		bestsize = bestsize + 1
	end

	return { a = besti, b = bestj, size = bestsize }
end

function SequenceMatcher:get_matching_blocks()
	if self.matching_blocks then
		return self.matching_blocks
	end
	local la, lb = #self.a, #self.b
	local queue = { { 1, la, 1, lb } }
	local matching_blocks = {}
	while #queue > 0 do
		local alo, ahi, blo, bhi = unpack(table.remove(queue))
		local x = self:find_longest_match(alo, ahi, blo, bhi)
		if x.size > 0 then
			table.insert(matching_blocks, x)
			if alo < x.a and blo < x.b then
				table.insert(queue, { alo, x.a - 1, blo, x.b - 1 })
			end
			if x.a + x.size <= ahi and x.b + x.size <= bhi then
				table.insert(queue, { x.a + x.size, ahi, x.b + x.size, bhi })
			end
		end
	end
	table.sort(matching_blocks, function(a, b)
		return a.a < b.a
	end)

	local non_adjacent = {}
	local i1, j1, k1 = 0, 0, 0
	if #matching_blocks > 0 then
		i1, j1, k1 = matching_blocks[1].a, matching_blocks[1].b, matching_blocks[1].size
	end

	for i = 2, #matching_blocks do
		local i2, j2, k2 = matching_blocks[i].a, matching_blocks[i].b, matching_blocks[i].size
		if i1 + k1 == i2 and j1 + k1 == j2 then
			k1 = k1 + k2
		else
			if k1 > 0 then
				table.insert(non_adjacent, { a = i1, b = j1, size = k1 })
			end
			i1, j1, k1 = i2, j2, k2
		end
	end
	if k1 > 0 then
		table.insert(non_adjacent, { a = i1, b = j1, size = k1 })
	end

	table.insert(non_adjacent, { a = la + 1, b = lb + 1, size = 0 })
	self.matching_blocks = non_adjacent
	return self.matching_blocks
end

function SequenceMatcher:get_opcodes()
	if self.opcodes then
		return self.opcodes
	end
	local i, j = 1, 1
	local answer = {}
	local matching_blocks = self:get_matching_blocks()
	for _, block in ipairs(matching_blocks) do
		local ai, bj, size = block.a, block.b, block.size
		local tag = ""
		if i < ai and j < bj then
			tag = "replace"
		elseif i < ai then
			tag = "delete"
		elseif j < bj then
			tag = "insert"
		end
		if tag ~= "" then
			table.insert(answer, { tag, i, ai - 1, j, bj - 1 })
		end
		i, j = ai + size, bj + size
		if size > 0 then
			table.insert(answer, { "equal", ai, i - 1, bj, j - 1 })
		end
	end
	self.opcodes = answer
	return answer
end

function SequenceMatcher:ratio()
	local matches = 0
	for _, block in ipairs(self:get_matching_blocks()) do
		matches = matches + block.size
	end
	local len_a = #self.a
	local len_b = #self.b
	if len_a + len_b > 0 then
		return 2.0 * matches / (len_a + len_b)
	end
	return 1.0
end

function SequenceMatcher:quick_ratio()
	if self.fullbcount == nil then
		self.fullbcount = {}
		for _, elt in ipairs(self.b) do
			self.fullbcount[elt] = (self.fullbcount[elt] or 0) + 1
		end
	end
	local avail = {}
	local matches = 0
	for _, elt in ipairs(self.a) do
		local numb
		if avail[elt] then
			numb = avail[elt]
		else
			numb = self.fullbcount[elt] or 0
		end
		avail[elt] = numb - 1
		if numb > 0 then
			matches = matches + 1
		end
	end
	local len_a = #self.a
	local len_b = #self.b
	if len_a + len_b > 0 then
		return 2.0 * matches / (len_a + len_b)
	end
	return 1.0
end

function SequenceMatcher:real_quick_ratio()
	local len_a = #self.a
	local len_b = #self.b
	if len_a + len_b > 0 then
		return 2.0 * math.min(len_a, len_b) / (len_a + len_b)
	end
	return 1.0
end

local function get_close_matches(word, possibilities, n, cutoff)
	n = n or 3
	cutoff = cutoff or 0.6
	if n <= 0 then
		error("n must be > 0")
	end
	if cutoff < 0.0 or cutoff > 1.0 then
		error("cutoff must be in [0.0, 1.0]")
	end
	local result = {}
	local s = SequenceMatcher:new()
	s:set_seq2(word)
	for _, x in ipairs(possibilities) do
		s:set_seq1(x)
		if s:real_quick_ratio() >= cutoff and s:quick_ratio() >= cutoff and s:ratio() >= cutoff then
			table.insert(result, { s:ratio(), x })
		end
	end
	table.sort(result, function(a, b)
		return a[1] > b[1]
	end)
	local final_result = {}
	for i = 1, math.min(n, #result) do
		table.insert(final_result, result[i][2])
	end
	return final_result
end

---@class Differ
---@field linejunk fun(line: string):boolean|nil
---@field charjunk fun(char: string):boolean|nil

local Differ = {}
Differ.__index = Differ

function Differ:new(linejunk, charjunk)
	local obj = setmetatable({}, Differ)
	obj.linejunk = linejunk
	obj.charjunk = charjunk
	return obj
end

function Differ:_dump(tag, x, lo, hi)
	local lines = {}
	for i = lo, hi do
		table.insert(lines, tag .. " " .. x[i])
	end
	return lines
end

function Differ:_plain_replace(a, alo, ahi, b, blo, bhi)
	local first, second
	if bhi - blo < ahi - alo then
		first = self:_dump("+", b, blo, bhi)
		second = self:_dump("-", a, alo, ahi)
	else
		first = self:_dump("-", a, alo, ahi)
		second = self:_dump("+", b, blo, bhi)
	end
	local lines = {}
	for _, line in ipairs(first) do
		table.insert(lines, line)
	end
	for _, line in ipairs(second) do
		table.insert(lines, line)
	end
	return lines
end

function Differ:compare(a, b)
	local cruncher = SequenceMatcher:new(self.linejunk, a, b)
	local result = {}
	for _, opcode in ipairs(cruncher:get_opcodes()) do
		local tag, alo, ahi, blo, bhi = unpack(opcode)
		local lines
		if tag == "replace" then
			lines = self:_plain_replace(a, alo, ahi, b, blo, bhi)
		elseif tag == "delete" then
			lines = self:_dump("-", a, alo, ahi)
		elseif tag == "insert" then
			lines = self:_dump("+", b, blo, bhi)
		elseif tag == "equal" then
			lines = self:_dump(" ", a, alo, ahi)
		else
			error("unknown tag " .. tag)
		end
		for _, line in ipairs(lines) do
			table.insert(result, line)
		end
	end
	return result
end

local function ndiff(a, b, linejunk, charjunk)
	local differ = Differ:new(linejunk, charjunk)
	return differ:compare(a, b)
end

return {
	SequenceMatcher = SequenceMatcher,
	get_close_matches = get_close_matches,
	Differ = Differ,
	ndiff = ndiff,
}
