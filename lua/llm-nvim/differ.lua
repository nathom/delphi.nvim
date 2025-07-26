local function splitlines(text)
	local lines = {}
	local start = 1
	while true do
		local next_nl = text:find("\n", start)
		if not next_nl then
			local remainder = text:sub(start)
			if #remainder > 0 then
				table.insert(lines, remainder)
			end
			break
		end
		table.insert(lines, text:sub(start, next_nl))
		start = next_nl + 1
	end
	return lines
end

-- =============================================================================
-- Core SequenceMatcher Implementation
-- =============================================================================

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
		local alo, ahi, blo, bhi = table.unpack(table.remove(stack))
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

-- =============================================================================
-- Interleaved Differ Implementation
-- =============================================================================

-- Compares two lists of lines and returns a list of prefixed lines for an
-- interleaved diff view. This is called on blocks already marked as 'replace'.
local function compare_lines(lines1, lines2)
	local sm = SequenceMatcher.new(lines1, lines2)
	local opcodes = sm:get_opcodes()
	local result_lines = {}

	for _, op in ipairs(opcodes) do
		local tag, i1, i2, j1, j2 = table.unpack(op)
		if tag == "replace" then
			-- **FIXED LOGIC**: Interleave deleted and added lines for a more
			-- readable, git-style diff within the replaced block.
			local n1 = i2 - i1
			local n2 = j2 - j1
			local max_n = math.max(n1, n2)
			for i = 0, max_n - 1 do
				if i < n1 then
					table.insert(result_lines, "- " .. lines1[i1 + i])
				end
				if i < n2 then
					table.insert(result_lines, "+ " .. lines2[j1 + i])
				end
			end
		elseif tag == "delete" then
			for i = i1, i2 - 1 do
				table.insert(result_lines, "- " .. lines1[i])
			end
		elseif tag == "insert" then
			for j = j1, j2 - 1 do
				table.insert(result_lines, "+ " .. lines2[j])
			end
		elseif tag == "equal" then
			for i = i1, i2 - 1 do
				table.insert(result_lines, "  " .. lines1[i])
			end
		end
	end
	return result_lines
end

-- =============================================================================
-- IncrementalDiffer Class
-- =============================================================================

local IncrementalDiffer = {}
IncrementalDiffer.__index = IncrementalDiffer

function IncrementalDiffer.new(left_text)
	local self = setmetatable({}, IncrementalDiffer)
	self.left_text = left_text
	self.left_lines = splitlines(left_text)
	self.right_text = ""
	return self
end

function IncrementalDiffer:update(token)
	self.right_text = self.right_text .. token
	self:pretty_print_diff()
end

function IncrementalDiffer:pretty_print_diff()
	local right_lines = splitlines(self.right_text)
	local sm = SequenceMatcher.new(self.left_lines, right_lines)
	local opcodes = sm:get_opcodes()

	local colors = {
		reset = "\27[0m",
		red = "\27[91m",
		green = "\27[92m",
	}

	os.execute("clear")
	print("--- Current Diff View ---")

	for i, op in ipairs(opcodes) do
		local tag, i1, i2, j1, j2 = table.unpack(op)
		local is_phantom_delete = (tag == "delete" and i == #opcodes)

		if tag == "replace" then
			local sub_lines1 = {}
			for k = i1, i2 - 1 do
				table.insert(sub_lines1, self.left_lines[k])
			end
			local sub_lines2 = {}
			for k = j1, j2 - 1 do
				table.insert(sub_lines2, right_lines[k])
			end

			local diff_lines = compare_lines(sub_lines1, sub_lines2)
			for _, line in ipairs(diff_lines) do
				local content = line:sub(3):gsub("[\r\n]", "")
				if line:sub(1, 2) == "- " then
					print(colors.red .. "- " .. content .. colors.reset)
				elseif line:sub(1, 2) == "+ " then
					print(colors.green .. "+ " .. content .. colors.reset)
				else
					print("  " .. content)
				end
			end
		elseif tag == "delete" and not is_phantom_delete then
			for k = i1, i2 - 1 do
				print(colors.red .. "- " .. self.left_lines[k]:gsub("[\r\n]", "") .. colors.reset)
			end
		elseif tag == "insert" then
			for k = j1, j2 - 1 do
				print(colors.green .. "+ " .. right_lines[k]:gsub("[\r\n]", "") .. colors.reset)
			end
		elseif tag == "equal" or is_phantom_delete then
			for k = i1, i2 - 1 do
				print("  " .. self.left_lines[k]:gsub("[\r\n]", ""))
			end
		end
	end
	print(string.rep("-", 40))
end
