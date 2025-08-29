local M = {}

---Extract streamed delta content from an OpenAI-like chunk
---@param chunk table|nil
---@return string
function M.get_stream_delta(chunk)
	if not chunk or not chunk.choices then
		return ""
	end
	local choice = chunk.choices[1]
	if choice and choice.delta and type(choice.delta.content) == "string" then
		return choice.delta.content
	end
	return ""
end

return M
