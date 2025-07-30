--- Grab markdown code block from streaming responses in O(n) time
--- with this state machine

local function idle(code, c)
	if c == "`" then
		return code, "TICK_1"
	end
	return code, "IDLE"
end

local function tick_1(code, c)
	if c == "`" then
		return code, "TICK_2"
	end
	return code, "IDLE"
end

local function tick_2(code, c)
	if c == "`" then
		return code, "TICK_3"
	end
	return code, "IDLE"
end

local function tick_3(code, c)
	-- allow arbitrary text after ``` until the next newline
	if c == "\n" then
		return code, "RECORDING"
	end
	return code, "TICK_3"
end

local function recording(code, c)
	if c == "`" then
		return code, "END_TICK_1"
	end
	return code .. c, "RECORDING"
end

local function end_tick_1(code, c)
	if c == "`" then
		return code, "END_TICK_2"
	end
	-- not actually a code fence, flush the pending tick
	return code .. "`" .. c, "RECORDING"
end

local function end_tick_2(code, c)
	if c == "`" then
		return code, "DONE"
	end
	-- not actually a code fence, flush the pending ticks
	return code .. "``" .. c, "RECORDING"
end

local function end_tick_3(code, c)
	if c == "`" then
		return code, "DONE"
	end
	return code .. c, "RECORDING"
end

local function done(code, _)
	return code, "DONE"
end

local state_to_fn = {
	IDLE = idle,
	TICK_1 = tick_1,
	TICK_2 = tick_2,
	TICK_3 = tick_3,
	RECORDING = recording,
	END_TICK_1 = end_tick_1,
	END_TICK_2 = end_tick_2,
	END_TICK_3 = end_tick_3,
	DONE = done,
}

local Extractor = {}
Extractor.__index = Extractor

function Extractor.new()
	return setmetatable({ state = "IDLE", code = "" }, Extractor)
end

function Extractor:update(delta)
	local new_code = ""
	for i = 1, #delta do
		if self.state == "DONE" then
			break
		end
		new_code, self.state = state_to_fn[self.state](new_code, delta:sub(i, i))
	end
	self.code = self.code .. new_code
	return new_code
end

function Extractor:get_code()
	if self.state == "END_TICK_1" then
		return self.code .. "`"
	elseif self.state == "END_TICK_2" then
		return self.code .. "``"
	end
	return self.code
end

local M = {}
M.Extractor = Extractor
return M
