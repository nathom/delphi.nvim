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
---@return vim.SystemObj?
function M.chat(model, body, cb)
	body.model = model.model_name
	local payload = vim.json.encode(body)

	local cmd = {
		"curl",
		"-sS",
		"--no-buffer",
		"-X",
		"POST",
		model.base_url .. "/chat/completions",
	}
	vim.list_extend(cmd, build_headers(model:get_api_key()))
	table.insert(cmd, "-d")
	table.insert(cmd, payload)

	local stdout_acc, stderr_acc = {}, {}

	--- Parse lines from streaming SSE
	local function handle_stream(data)
		if not data then
			return
		end
		for line in data:gmatch("[^\r\n]+") do
			if not vim.startswith(line, "data:") then
				goto continue
			end
			local chunk = vim.trim(line:sub(6))
			if chunk == "[DONE]" then
				if cb.on_chunk then
					vim.schedule(function()
						cb.on_chunk(nil, true)
					end)
				end
			else
				local ok, decoded = pcall(vim.json.decode, chunk, {
					luanil = { object = true, array = true },
				})
				if ok and decoded and cb.on_chunk then
					vim.schedule(function()
						cb.on_chunk(decoded)
					end)
				end
			end
			::continue::
		end
	end

	local function handle_full_exit(code)
		if code ~= 0 then
			if cb.on_error then
				vim.schedule(function()
					cb.on_error(table.concat(stderr_acc, ""))
				end)
			end
			return
		end
		local raw = table.concat(stdout_acc, "")
		local ok, decoded = pcall(vim.json.decode, raw, {
			luanil = { object = true, array = true },
		})
		if not ok then
			if cb.on_error then
				vim.schedule(function()
					cb.on_error("[openai.lua] JSON decode failed")
				end)
			end
			return
		end
		if cb.on_complete then
			vim.schedule(function()
				cb.on_complete(decoded)
			end)
		end
	end

	-- Spawn curl via libuv (non-blocking)
	local handle
	handle = vim.system(cmd, {
		text = true,
		stdout = function(_, data)
			if body.stream then
				handle_stream(data)
			else
				if data then
					stdout_acc[#stdout_acc + 1] = data
				end
			end
		end,
		stderr = function(_, data)
			if data then
				stderr_acc[#stderr_acc + 1] = data
			end
		end,
		exit_cb = function(_, code)
			if body.stream then
				if code ~= 0 and cb.on_error then
					vim.schedule(function()
						cb.on_error(table.concat(stderr_acc, ""))
					end)
				end
			else
				handle_full_exit(code)
			end
		end,
	})

	return handle
end

return M
