-- Extract code enclosed in <delphi:refactored_code> tags from a streaming
-- response. Works in O(n) overall and produces incremental output.

local START_TAG = "<delphi:refactored_code>"
local END_TAG = "</delphi:refactored_code>"
local THINK_START_TAG = "<delphi:think>"
local THINK_END_TAG = "</delphi:think>"

---@class Extractor
---@field state 'SEARCH_START'|'AFTER_START'|'OPEN_FENCE'|'SKIP_LANG'|'RECORDING'|'MAYBE_END'|'DONE'
---@field start_idx integer
---@field end_idx integer
---@field tick_count integer
---@field pending string
---@field finished boolean
---@field code string
---@field t_start_idx integer        -- think start tag match index
---@field t_end_idx integer          -- think end tag match index
---@field t_pending string           -- pending buffer when maybe matching THINK_END_TAG
---@field t_maybe_end boolean        -- in tentative THINK_END_TAG match
---@field t_in boolean               -- currently inside <delphi:think>…</delphi:think>
---@field t_chars integer            -- number of characters seen between think tags (excludes tags)
local Extractor = {}
Extractor.__index = Extractor

function Extractor.new()
	---@type Extractor
	local e = {
		state = "SEARCH_START",
		start_idx = 0,
		end_idx = 0,
		tick_count = 0,
		pending = "",
		finished = false,
		code = "",
		-- think tracking
		t_start_idx = 0,
		t_end_idx = 0,
		t_pending = "",
		t_maybe_end = false,
		t_in = false,
		t_chars = 0,
	}
	return setmetatable(e, Extractor)
end

function Extractor:_think_step(ch)
	if not self.t_in then
		-- match THINK_START_TAG
		if ch == THINK_START_TAG:sub(self.t_start_idx + 1, self.t_start_idx + 1) then
			self.t_start_idx = self.t_start_idx + 1
			if self.t_start_idx == #THINK_START_TAG then
				-- entered think; reset trackers for end tag
				self.t_in = true
				self.t_start_idx = 0
				self.t_end_idx = 0
				self.t_maybe_end = false
				self.t_pending = ""
			end
		else
			self.t_start_idx = (ch == THINK_START_TAG:sub(1, 1)) and 1 or 0
		end
		return false -- not in think yet
	end

	-- We are inside think: either counting content or checking for end tag.
	if self.t_maybe_end then
		if ch == THINK_END_TAG:sub(self.t_end_idx + 1, self.t_end_idx + 1) then
			self.t_end_idx = self.t_end_idx + 1
			self.t_pending = self.t_pending .. ch
			if self.t_end_idx == #THINK_END_TAG then
				-- close think; do not count tag characters
				self.t_in = false
				self.t_maybe_end = false
				self.t_end_idx = 0
				self.t_pending = ""
			end
		else
			-- false alarm: pending buffer is real content
			self.t_chars = self.t_chars + #self.t_pending + 1
			self.t_pending = ""
			self.t_end_idx = 0
			self.t_maybe_end = false
		end
	else
		if ch == "<" then
			self.t_maybe_end = true
			self.t_end_idx = 1
			self.t_pending = "<"
		else
			self.t_chars = self.t_chars + 1
		end
	end
	return true -- we are (or were just now) inside think; caller should skip main FSM work
end

---@param delta string
---@return string
function Extractor:update(delta)
	if self.finished or #delta == 0 then
		return ""
	end
	local out = ""
	for i = 1, #delta do
		local ch = delta:sub(i, i)

		-- Always advance think FSM first; if we're inside think, suppress main FSM.
		local was_thinking = self:_think_step(ch)
		if was_thinking then
			-- Do not emit think content or let it contaminate code/output.
			-- Continue to next char; when think closes, main FSM resumes.
			goto continue
		end

		if self.state == "SEARCH_START" then
			if ch == START_TAG:sub(self.start_idx + 1, self.start_idx + 1) then
				self.start_idx = self.start_idx + 1
				if self.start_idx == #START_TAG then
					self.state = "AFTER_START"
					self.start_idx = 0
				end
			else
				self.start_idx = (ch == START_TAG:sub(1, 1)) and 1 or 0
			end
		elseif self.state == "AFTER_START" then
			if ch == "\n" then
				self.state = "OPEN_FENCE"
				self.tick_count = 0
			elseif ch == "`" then
				self.state = "OPEN_FENCE"
				self.tick_count = 1
			else
				out = out .. ch
				self.code = self.code .. ch
				self.state = "RECORDING"
			end
		elseif self.state == "OPEN_FENCE" then
			if self.tick_count < 3 then
				if ch == "`" then
					self.tick_count = self.tick_count + 1
					if self.tick_count == 3 then
						self.state = "SKIP_LANG" -- optional language + newline
					end
				else
					-- not actually a fence
					local ticks = string.rep("`", self.tick_count)
					out = out .. ticks .. ch
					self.code = self.code .. ticks .. ch
					self.state = "RECORDING"
					self.tick_count = 0
				end
			end
		elseif self.state == "SKIP_LANG" then
			if ch == "\n" then
				self.state = "RECORDING"
			end
		elseif self.state == "RECORDING" then
			if ch == "<" then
				self.state = "MAYBE_END"
				self.end_idx = 1
				self.pending = "<"
			else
				out = out .. ch
				self.code = self.code .. ch
			end
		elseif self.state == "MAYBE_END" then
			if ch == END_TAG:sub(self.end_idx + 1, self.end_idx + 1) then
				self.end_idx = self.end_idx + 1
				self.pending = self.pending .. ch
				if self.end_idx == #END_TAG then
					self.code = self.code:gsub("```%s*$", "")
					self.state = "DONE"
					self.finished = true
					break
				end
			else
				out = out .. self.pending .. ch
				self.code = self.code .. self.pending .. ch
				self.pending = ""
				self.end_idx = 0
				self.state = "RECORDING"
			end
		end
		::continue::
	end
	return out
end

---@return string
function Extractor:get_code()
	return self.code
end

---@return boolean
function Extractor:is_thinking()
	return self.t_in
end

---@return integer
function Extractor:num_think_chars()
	return self.t_chars
end

local M = {}
M.Extractor = Extractor
return M
