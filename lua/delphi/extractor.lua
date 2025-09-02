local START_TAG = "<delphi:new_content>"
local END_TAG = "</delphi:new_content>"

---@class Extractor
---@field state 'SEARCH_START'|'AFTER_START'|'OPEN_FENCE'|'SKIP_LANG'|'RECORDING'|'MAYBE_END'|'DONE'
---@field start_idx integer
---@field end_idx integer
---@field tick_count integer
---@field pending string
---@field finished boolean
---@field code string
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
	}
	return setmetatable(e, Extractor)
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
			elseif ch == "<" then
				-- Could be an immediate closing tag (empty content); don't emit yet
				self.state = "MAYBE_END"
				self.end_idx = 1
				self.pending = "<"
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
						-- wait for optional language + newline
						self.state = "SKIP_LANG"
					end
				else
					-- not actually a fence; however, if the very next token is
					-- a '<', it may be the closing tag for empty content.
					if ch == "<" and self.tick_count == 0 then
						self.state = "MAYBE_END"
						self.end_idx = 1
						self.pending = "<"
					else
						out = out .. string.rep("`", self.tick_count) .. ch
						self.code = self.code .. string.rep("`", self.tick_count) .. ch
						self.state = "RECORDING"
					end
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
	end
	return out
end

---@return string
function Extractor:get_code()
	return self.code
end

local M = {}
M.Extractor = Extractor
return M
