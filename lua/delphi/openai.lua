-- Example (streaming):
--   local openai = require('openai')
--   openai.setup{ api_key = os.getenv('OPENAI_API_KEY') }
--   openai.chat({
--       model = 'gpt-4o',
--       stream = true,
--       messages = {{role='user', content='Hello'}}
--   }, {
--       on_chunk   = vim.schedule_wrap(function(chunk)
--           -- chunk.choices[1].delta.content
--       end),
--       on_error   = vim.notify,
--   })

local Job = require("plenary.job")

local M = {}

--- Internal: build curl header list
---@param api_key string
local function build_headers(api_key)
	local hdr = {
		"-H",
		"Content-Type: application/json",
		"-H",
		"Authorization: Bearer " .. (api_key or ""),
	}
	return hdr
end

--- Send a chat completion request.
---@param model Model
---@param body table
---@param cb   {on_chunk: function, on_complete: function, on_error: function}
---@return Job
function M.chat(model, body, cb)
	body.model = model.model_name
	cb = cb or {}
	local payload = vim.json.encode(body)

	local args = {
		"-sS",
		"--no-buffer",
		"--fail-with-body",
		"-X",
		"POST",
		model.base_url .. "/chat/completions",
	}
	vim.list_extend(args, build_headers(model:get_api_key()))
	table.insert(args, "-d")
	table.insert(args, payload)

	local stdout_acc, stderr_acc = {}, {}

	local function handle_stream(chunk)
		if not chunk then
			return
		end
		for line in chunk:gmatch("[^\r\n]+") do
			if not vim.startswith(line, "data:") then
				goto continue
			end
			local payload_line = vim.trim(line:sub(6))
			if payload_line == "[DONE]" then
				if cb.on_chunk then
					cb.on_chunk(nil, true)
				end
			else
				local ok, decoded = pcall(vim.json.decode, payload_line, {
					luanil = { object = true, array = true },
				})
				if ok and decoded then
					if decoded.error then
						if cb.on_error then
							cb.on_error(
								string.format(
									"OpenAI %s: %s",
									tostring(decoded.error.code or ""),
									decoded.error.message or ""
								)
							)
						end
					elseif cb.on_chunk then
						cb.on_chunk(decoded)
					end
				else
					table.insert(stderr_acc, payload_line)
				end
			end
			::continue::
		end
	end

	local function finalize(code)
		local stderr = table.concat(stderr_acc, "")
		if code ~= 0 then
			if cb.on_error then
				cb.on_error(stderr ~= "" and stderr or string.format("curl exited with code %d", code))
			end
			return
		end
		if not body.stream then
			local raw = table.concat(stdout_acc, "")
			local ok, decoded = pcall(vim.json.decode, raw, {
				luanil = { object = true, array = true },
			})
			if not ok or not decoded then
				if cb.on_error then
					cb.on_error("openai: invalid JSON")
				end
				return
			end
			if decoded.error then
				if cb.on_error then
					cb.on_error(
						string.format("OpenAI %s: %s", tostring(decoded.error.code or ""), decoded.error.message or "")
					)
				end
				return
			end
			if cb.on_complete then
				cb.on_complete(decoded)
			end
		end
	end

	local job = Job:new({
		command = "curl",
		args = args,
		on_stdout = vim.schedule_wrap(function(_, data)
			if body.stream then
				handle_stream(data)
			else
				if data then
					stdout_acc[#stdout_acc + 1] = data
				end
			end
		end),
		on_stderr = vim.schedule_wrap(function(_, data)
			if data then
				stderr_acc[#stderr_acc + 1] = data
			end
		end),
		on_exit = vim.schedule_wrap(function(_, code)
			finalize(code)
		end),
	})

	job:start()
	return job
end

return M
