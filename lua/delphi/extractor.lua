--- Grab fenced code from streaming responses with a simple state machine

---@class Extractor
---@field fence_len integer
---@field state 'WAIT_START' | 'SKIP_INFO' | 'RECORDING' | 'END' | 'DONE'
---@field ticks integer
---@field code string
local Extractor = {}
Extractor.__index = Extractor

---Create a new Extractor
---@param fence_len integer
---@return Extractor
function Extractor.new(fence_len)
	fence_len = fence_len or 3
	return setmetatable({ state = "WAIT_START", ticks = 0, fence_len = fence_len, code = "" }, Extractor)
end

---Update the extractor with streamed text
---@param delta string
---@return string new_code
function Extractor:update(delta)
	local new_code = ""
	for i = 1, #delta do
		local c = delta:sub(i, i)
		if self.state == "DONE" then
			break
		elseif self.state == "WAIT_START" then
			if c == "`" then
				self.ticks = self.ticks + 1
				if self.ticks == self.fence_len then
					self.state = "SKIP_INFO"
					self.ticks = 0
				end
			else
				self.ticks = 0
			end
		elseif self.state == "SKIP_INFO" then
			if c == "\n" then
				self.state = "RECORDING"
			end
		elseif self.state == "RECORDING" then
			if c == "`" then
				self.ticks = 1
				self.state = "END"
			else
				new_code = new_code .. c
			end
		elseif self.state == "END" then
			if c == "`" then
				self.ticks = self.ticks + 1
				if self.ticks == self.fence_len then
					self.state = "DONE"
				end
			else
				new_code = new_code .. string.rep("`", self.ticks) .. c
				self.ticks = 0
				self.state = "RECORDING"
			end
		end
	end
	self.code = self.code .. new_code
	return new_code
end

---Return all accumulated code (flushes unfinished fences)
---@return string
function Extractor:get_code()
	if self.state == "END" then
		return self.code .. string.rep("`", self.ticks)
	end
	return self.code
end

local M = {}
M.Extractor = Extractor
return M
