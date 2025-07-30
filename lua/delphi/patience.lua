-- A type definition for a Longest Common Subsequence (LCS).
-- All indices are 1-based and relative to the slices being compared at that time.
---@class Lcs
---@field before_start integer The 1-based starting index in the 'before' slice.
---@field after_start integer The 1-based starting index in the 'after' slice.
---@field length integer The length of the common subsequence.

-- In the original Rust code, chains longer than this are ignored to avoid
-- performance issues with extremely common tokens.
local MAX_CHAIN_LEN = 63

--- A helper function to create a slice of a table.
---@param tbl table The table to slice.
---@param i integer The 1-based start index (inclusive).
---@param j integer The 1-based end index (inclusive).
---@return table
local function slice(tbl, i, j)
	local new_tbl = {}
	if i > j then
		return new_tbl
	end
	for k = i, j do
		table.insert(new_tbl, tbl[k])
	end
	return new_tbl
end

-- A class to map unique objects to integer IDs.
---@class Interner
---@field mapping table<any, integer>
---@field tokens table<integer, any>
local Interner = {}
Interner.__index = Interner

---@return Interner
function Interner:new()
	local o = {}
	setmetatable(o, self)
	o.mapping = {}
	o.tokens = {}
	return o
end

---@param obj any
---@return integer
function Interner:intern(obj)
	if self.mapping[obj] == nil then
		local new_id = #self.tokens + 1
		self.mapping[obj] = new_id
		self.tokens[new_id] = obj
	end
	return self.mapping[obj]
end

--- A Lua port of the histogram-based patience diff algorithm.
---
--- This class takes two sequences of items (e.g., lines of text), finds the
--- differences, and reports them as two boolean tables indicating additions
--- and removals.
---@class PatienceDiff
---@field a string[] The "before" sequence of items.
---@field b string[] The "after"sequence of items.
---@field _interner Interner
---@field a_tokens integer[]
---@field b_tokens integer[]
local PatienceDiff = {}
PatienceDiff.__index = PatienceDiff

--- Initializes the differ with two lists of hashable items (e.g., strings).
---@param a string[] The "before" sequence of items.
---@param b string[] The "after" sequence of items.
---@return PatienceDiff
function PatienceDiff:new(a, b)
	local o = {}
	setmetatable(o, self)

	o.a = a
	o.b = b
	o._interner = Interner:new()

	o.a_tokens = {}
	for _, item in ipairs(o.a) do
		table.insert(o.a_tokens, o._interner:intern(item))
	end

	o.b_tokens = {}
	for _, item in ipairs(o.b) do
		table.insert(o.b_tokens, o._interner:intern(item))
	end

	return o
end

--- Finds the best Longest Common Subsequence (LCS) between two slices.
--- This method mirrors the logic in `histogram/lcs.rs`. It prioritizes
--- LCSs that are built from rarer tokens.
---@param before_slice integer[]
---@param after_slice integer[]
---@param histogram table<integer, integer[]>
---@return Lcs?
function PatienceDiff:_find_lcs(before_slice, after_slice, histogram)
	local min_occurrences = MAX_CHAIN_LEN + 1
	---@type Lcs
	local best_lcs = { before_start = 1, after_start = 1, length = 0 }
	local found_cs = false

	local after_pos = 1
	while after_pos <= #after_slice do
		local token = after_slice[after_pos]

		local occurrences_in_before = histogram[token] or {}
		local num_occurrences = #occurrences_in_before

		if num_occurrences == 0 or num_occurrences > min_occurrences then
			after_pos = after_pos + 1
		else
			found_cs = true

			local next_after_pos = after_pos + 1
			for _, before_pos in ipairs(occurrences_in_before) do
				-- Extend match backwards
				local start1, start2 = before_pos, after_pos
				local current_min_occurrences = num_occurrences
				while start1 > 1 and start2 > 1 and before_slice[start1 - 1] == after_slice[start2 - 1] do
					start1 = start1 - 1
					start2 = start2 - 1
					local new_occ = #(histogram[before_slice[start1]] or {})
					current_min_occurrences = math.min(current_min_occurrences, new_occ)
				end

				-- Extend match forwards
				local end1, end2 = before_pos, after_pos
				while
					end1 < #before_slice
					and end2 < #after_slice
					and before_slice[end1 + 1] == after_slice[end2 + 1]
				do
					local new_occ = #(histogram[before_slice[end1 + 1]] or {})
					current_min_occurrences = math.min(current_min_occurrences, new_occ)
					end1 = end1 + 1
					end2 = end2 + 1
				end

				local length = end1 - start1 + 1

				-- Update best LCS if this one is longer, or same length but rarer
				if
					length > best_lcs.length
					or (length == best_lcs.length and current_min_occurrences < min_occurrences)
				then
					min_occurrences = current_min_occurrences
					best_lcs = { before_start = start1, after_start = start2, length = length }
				end

				if end2 >= next_after_pos then
					next_after_pos = end2 + 1
				end
			end
			after_pos = next_after_pos
		end
	end

	-- Corresponds to the success condition in Rust. If no common sequence
	-- was found, or all common sequences are too frequent, we might need
	-- to fall back to a different algorithm.
	if found_cs and min_occurrences <= MAX_CHAIN_LEN then
		return best_lcs
	else
		return nil -- Fallback case
	end
end

--- Computes the diff between sequences a and b.
---@return boolean[], boolean[] A tuple `(removed, added)`, where `removed` is a boolean list indicating removed lines from `a`, and `added` is a boolean list indicating added lines to `b`.
function PatienceDiff:diff()
	-- Result tables, initialized to all false
	---@type boolean[]
	local removed = {}
	for _ = 1, #self.a_tokens do
		table.insert(removed, false)
	end
	---@type boolean[]
	local added = {}
	for _ = 1, #self.b_tokens do
		table.insert(added, false)
	end

	-- A stack for iterative, depth-first processing of subproblems
	-- Each item is (b_start, b_end, a_start, a_end) for the original token lists
	---@type table[]
	local stack = { { 1, #self.a_tokens, 1, #self.b_tokens } }

	while #stack > 0 do
		local entry = table.remove(stack)
		local b_start, b_end, a_start, a_end = entry[1], entry[2], entry[3], entry[4]

		local before_slice = slice(self.a_tokens, b_start, b_end)
		local after_slice = slice(self.b_tokens, a_start, a_end)

		-- Base cases: if one of the slices is empty, the other is all changes
		if #before_slice == 0 then
			for i = a_start, a_end do
				added[i] = true
			end
		elseif #after_slice == 0 then
			for i = b_start, b_end do
				removed[i] = true
			end
		else
			-- 1. Build a histogram of token occurrences for the 'before' slice
			-- The indices stored are 1-based and relative to the slice itself.
			---@type table<integer, integer[]>
			local histogram = {}
			for i, token in ipairs(before_slice) do
				if histogram[token] == nil then
					histogram[token] = {}
				end
				table.insert(histogram[token], i)
			end

			-- 2. Find the Longest Common Subsequence (LCS)
			local lcs = self:_find_lcs(before_slice, after_slice, histogram)

			-- 3. Recurse on the pieces before and after the LCS
			-- If no usable LCS is found, mark the whole slice as changed.
			if lcs == nil or lcs.length == 0 then
				for i = b_start, b_end do
					removed[i] = true
				end
				for i = a_start, a_end do
					added[i] = true
				end
			else
				-- The LCS itself is common, so its lines are not marked.
				-- Convert slice-relative LCS indices to absolute indices.

				-- Push the subproblem *after* the LCS to the stack
				local lcs_b_abs_end = b_start + lcs.before_start + lcs.length - 2
				local lcs_a_abs_end = a_start + lcs.after_start + lcs.length - 2
				table.insert(stack, { lcs_b_abs_end + 1, b_end, lcs_a_abs_end + 1, a_end })

				-- Push the subproblem *before* the LCS to the stack
				local lcs_b_abs_start = b_start + lcs.before_start - 1
				local lcs_a_abs_start = a_start + lcs.after_start - 1
				table.insert(stack, { b_start, lcs_b_abs_start - 1, a_start, lcs_a_abs_start - 1 })
			end
		end
	end

	return removed, added
end

--- A basic utility to print a unified diff from the algorithm's output.
---@param a string[]
---@param b string[]
---@param removed boolean[]
---@param added boolean[]
---@param context_len? integer
function print_unified_diff(a, b, removed, added, context_len)
	context_len = context_len or 3
	local a_len, b_len = #a, #b

	-- Find hunks of changes
	---@type table[]
	local hunks = {}
	local i, j = 1, 1
	while i <= a_len or j <= b_len do
		if (i <= a_len and removed[i]) or (j <= b_len and added[j]) then
			local hunk_a_start, hunk_b_start = i, j

			-- Find the end of the removal part
			local hunk_a_end = hunk_a_start
			while hunk_a_end <= a_len and removed[hunk_a_end] do
				hunk_a_end = hunk_a_end + 1
			end

			-- Find the end of the addition part
			local hunk_b_end = hunk_b_start
			while hunk_b_end <= b_len and added[hunk_b_end] do
				hunk_b_end = hunk_b_end + 1
			end

			-- Store hunk with 1-based start and one-past-the-end index
			table.insert(hunks, { hunk_a_start, hunk_a_end, hunk_b_start, hunk_b_end })
			i, j = hunk_a_end, hunk_b_end
		else
			i = i + 1
			j = j + 1
		end
	end

	-- Print hunks with context
	local last_a_end = 0
	for _, hunk in ipairs(hunks) do
		local a_start, a_end, b_start, b_end = hunk[1], hunk[2], hunk[3], hunk[4]

		-- Check if hunks are far apart
		if (a_start - last_a_end) > (2 * context_len) and last_a_end > 0 then
			print("...")
		end

		-- Hunk header
		print(string.format("@@ -%d,%d +%d,%d @@", a_start, a_end - a_start, b_start, b_end - b_start))

		-- Leading context
		local context_start_a = math.max(1, a_start - context_len)
		for k = context_start_a, a_start - 1 do
			if a[k] then
				print("  " .. a[k])
			end
		end

		-- Removed lines
		for k = a_start, a_end - 1 do
			if a[k] then
				print("- " .. a[k])
			end
		end

		-- Added lines
		for k = b_start, b_end - 1 do
			if b[k] then
				print("+ " .. b[k])
			end
		end

		-- Trailing context
		local context_end_a = math.min(a_len, (a_end - 1) + context_len)
		for k = a_end, context_end_a do
			if a[k] then
				print("  " .. a[k])
			end
		end

		last_a_end = a_end
	end
end

--- Splits a string into lines.
---@param str string
---@return string[]
local function splitlines(str)
	local lines = {}
	-- Handle trailing newline correctly by adding a dummy char if needed
	if str:sub(-1) == "\n" then
		str = str .. " "
	end
	for line in str:gmatch("([^\n]*)\n?") do
		-- Trim the dummy char from the last line if it exists
		if line:sub(-1) == " " and #lines == select(2, str:gsub("\n", "")) then
			line = line:sub(1, -2)
		end
		table.insert(lines, line)
	end
	-- Remove the last line if the original string ended with a newline and was otherwise empty or just newlines.
	if #lines > 0 and lines[#lines] == "" and select(2, str:gsub("[^\n]", "")) == #str - 1 then
		table.remove(lines)
	end
	return lines
end

--- A wrapper class to provide difflib-compatible interface
---@class Differ
local Differ = {}
Differ.__index = Differ

--- Creates a new Differ instance
---@param linejunk? function Optional function to determine if a line is junk
---@param charjunk? function Optional function to determine if a character is junk (unused in patience diff)
---@return Differ
function Differ:new(linejunk, charjunk)
	local obj = setmetatable({}, Differ)
	obj.linejunk = linejunk
	obj.charjunk = charjunk
	return obj
end

--- Compare two sequences of lines and return diff in difflib format
---@param a string[] The "before" sequence of lines
---@param b string[] The "after" sequence of lines
---@return string[] Array of diff lines with prefixes: "- ", "+ ", "  "
function Differ:compare(a, b)
	local differ = PatienceDiff:new(a, b)
	local removed, added = differ:diff()

	local result = {}
	local i, j = 1, 1

	while i <= #a or j <= #b do
		if i <= #a and removed[i] then
			-- Line removed from a
			table.insert(result, "- " .. a[i])
			i = i + 1
		elseif j <= #b and added[j] then
			-- Line added to b
			table.insert(result, "+ " .. b[j])
			j = j + 1
		else
			-- Line is common (equal)
			if i <= #a then
				table.insert(result, "  " .. a[i])
			end
			i = i + 1
			j = j + 1
		end
	end

	return result
end

return {
	PatienceDiff = PatienceDiff,
	Differ = Differ,
	splitlines = splitlines,
	print_unified_diff = print_unified_diff,
}
