-- All indices are 1-based and relative to the slices being compared at that time.
---@class Lcs
---@field before_start integer The 1-based starting index in the 'before' slice.
---@field after_start integer The 1-based starting index in the 'after' slice.
---@field length integer The length of the common subsequence.

-- In the original Rust code, chains longer than this are ignored to avoid
-- performance issues with extremely common tokens.
local MAX_CHAIN_LEN = 63
local SMALL_FALLBACK_THRESHOLD = 64

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

--- Determine if a token id is considered junk (not useful as an anchor)
---@param token_id integer
---@return boolean
function PatienceDiff:_is_junk_token(token_id)
	local s = self._interner.tokens[token_id]
	return type(s) == "string" and s:match("^%s*$") ~= nil
end

--- Build a histogram for the 'before' range [b_start, b_end], ignoring junk and very common tokens.
---@param b_start integer
---@param b_end integer
---@return table<integer, integer[]> histogram  -- token -> list of ABSOLUTE positions in a_tokens within the range
function PatienceDiff:_build_histogram(b_start, b_end)
	---@type table<integer, integer>
	local counts = {}
	for i = b_start, b_end do
		local t = self.a_tokens[i]
		if not self:_is_junk_token(t) then
			counts[t] = (counts[t] or 0) + 1
		end
	end
	---@type table<integer, integer[]>
	local histogram = {}
	for i = b_start, b_end do
		local t = self.a_tokens[i]
		if not self:_is_junk_token(t) then
			if (counts[t] or 0) <= MAX_CHAIN_LEN then
				local arr = histogram[t]
				if arr == nil then
					arr = {}
					histogram[t] = arr
				end
				table.insert(arr, i) -- store ABSOLUTE index
			end
		end
	end
	return histogram
end

--- Finds the best contiguous LCS between two ranges without allocating slices.
--- This method mirrors the logic in `histogram/lcs.rs`. It prioritizes
--- LCSs that are built from rarer tokens.
---@param b_start integer  start index into a_tokens (inclusive)
---@param b_end integer    end index into a_tokens (inclusive)
---@param a_start integer  start index into b_tokens (inclusive)
---@param a_end integer    end index into b_tokens (inclusive)
---@param histogram table<integer, integer[]>  token -> list of ABS positions in [b_start,b_end]
---@return Lcs?
function PatienceDiff:_find_lcs_indexed(b_start, b_end, a_start, a_end, histogram)
	local min_occurrences = MAX_CHAIN_LEN + 1
	---@type Lcs
	local best_lcs = { before_start = b_start, after_start = a_start, length = 0 }
	local found_cs = false

	local after_pos = a_start
	while after_pos <= a_end do
		local token = self.b_tokens[after_pos]

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
				while
					start1 > b_start
					and start2 > a_start
					and self.a_tokens[start1 - 1] == self.b_tokens[start2 - 1]
				do
					start1 = start1 - 1
					start2 = start2 - 1
					local new_occ = #(histogram[self.a_tokens[start1]] or {})
					current_min_occurrences = math.min(current_min_occurrences, new_occ)
				end

				-- Extend match forwards
				local end1, end2 = before_pos, after_pos
				while end1 < b_end and end2 < a_end and self.a_tokens[end1 + 1] == self.b_tokens[end2 + 1] do
					local new_occ = #(histogram[self.a_tokens[end1 + 1]] or {})
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

	if found_cs and min_occurrences <= MAX_CHAIN_LEN then
		return best_lcs
	else
		return nil
	end
end

--- Small-range dynamic programming diff for improved quality on tiny slices.
---@param b_start integer
---@param b_end integer
---@param a_start integer
---@param a_end integer
---@param removed boolean[]
---@param added boolean[]
function PatienceDiff:_dp_diff_small(b_start, b_end, a_start, a_end, removed, added)
	local m = b_end - b_start + 1
	local n = a_end - a_start + 1
	if m <= 0 and n <= 0 then
		return
	end
	-- Build local token arrays for the slice (kept small by threshold)
	---@type integer[]
	local A = {}
	---@type integer[]
	local B = {}
	for i = 1, m do
		A[i] = self.a_tokens[b_start + i - 1]
	end
	for j = 1, n do
		B[j] = self.b_tokens[a_start + j - 1]
	end
	-- LCS length DP table (m+1) x (n+1)
	local L = {}
	for i = 0, m do
		L[i] = {}
		for j = 0, n do
			L[i][j] = 0
		end
	end
	for i = m - 1, 0, -1 do
		for j = n - 1, 0, -1 do
			if A[i + 1] == B[j + 1] then
				L[i][j] = 1 + L[i + 1][j + 1]
			else
				local v1 = L[i + 1][j]
				local v2 = L[i][j + 1]
				L[i][j] = (v1 >= v2) and v1 or v2
			end
		end
	end
	-- Reconstruct diff and mark booleans
	local i, j = 0, 0
	while i < m and j < n do
		if A[i + 1] == B[j + 1] then
			i = i + 1
			j = j + 1
		elseif L[i + 1][j] >= L[i][j + 1] then
			removed[b_start + i] = true
			i = i + 1
		else
			added[a_start + j] = true
			j = j + 1
		end
	end
	while i < m do
		removed[b_start + i] = true
		i = i + 1
	end
	while j < n do
		added[a_start + j] = true
		j = j + 1
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

		-- Base cases using indices
		if b_start > b_end then
			for i = a_start, a_end do
				added[i] = true
			end
		elseif a_start > a_end then
			for i = b_start, b_end do
				removed[i] = true
			end
		else
			-- 1. Build histogram for before range (index-based)
			local histogram = self:_build_histogram(b_start, b_end)

			-- 2. Find an LCS anchor in these ranges
			local lcs = self:_find_lcs_indexed(b_start, b_end, a_start, a_end, histogram)

			-- 3. Recurse on the pieces before and after the LCS
			if lcs == nil or lcs.length == 0 then
				local m = b_end - b_start + 1
				local n = a_end - a_start + 1
				if m <= SMALL_FALLBACK_THRESHOLD and n <= SMALL_FALLBACK_THRESHOLD then
					self:_dp_diff_small(b_start, b_end, a_start, a_end, removed, added)
				else
					for i = b_start, b_end do
						removed[i] = true
					end
					for i = a_start, a_end do
						added[i] = true
					end
				end
			else
				-- The LCS block is common. Queue subproblems around it (absolute indices already)
				local lcs_b_abs_start = lcs.before_start
				local lcs_b_abs_end = lcs.before_start + lcs.length - 1
				local lcs_a_abs_start = lcs.after_start
				local lcs_a_abs_end = lcs.after_start + lcs.length - 1

				-- After the LCS
				table.insert(stack, { lcs_b_abs_end + 1, b_end, lcs_a_abs_end + 1, a_end })
				-- Before the LCS
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
-- (splitlines removed; not used by plugin)

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
		local is_removed = (i <= #a) and removed[i] or false
		local is_added = (j <= #b) and added[j] or false

		if is_removed then
			table.insert(result, "- " .. a[i])
			i = i + 1
		elseif is_added then
			table.insert(result, "+ " .. b[j])
			j = j + 1
		elseif (i <= #a) and (j <= #b) then
			table.insert(result, "  " .. a[i])
			i = i + 1
			j = j + 1
		else
			-- Safety fallbacks for mismatched tails (should be rare)
			if i <= #a then
				table.insert(result, "- " .. a[i])
				i = i + 1
			end
			if j <= #b then
				table.insert(result, "+ " .. b[j])
				j = j + 1
			end
		end
	end

	return result
end

return {
	PatienceDiff = PatienceDiff,
	Differ = Differ,
	print_unified_diff = print_unified_diff,
}
