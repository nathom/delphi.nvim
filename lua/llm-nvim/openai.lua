-- openai.lua – minimal OpenAI Chat Completions client for Neovim (≥0.10)
--
-- Design goals
--   * Zero external dependencies except curl & plenary (optional)
--   * Full async, non-blocking, works inside Neovim event loop
--   * Supports both blocking (non-stream) and streaming usage via callbacks
--   * Implements official OpenAI Chat Completions spec (2025-07-25 revision)
--
-- Public API
--   setup(cfg)                     → configure api_key, base_url, etc.
--   chat(args, cbs) → handle       → send request. If args.stream=true the
--                                     response is Server-Sent Events; chunks
--                                     arrive via cbs.on_chunk(JSON).
--                                     For non-stream, cbs.on_complete(JSON)
--                                     gets the full parsed body.
--                                     Returns the vim.system handle so the
--                                     caller may :kill() to cancel.
--
--   args  → table mirroring OpenAI /chat/completions payload
--   cbs   → { on_chunk = fn(chunk), on_complete = fn(resp),
--             on_done = fn(), on_error = fn(msg) }
--
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
--       on_done    = function() print('done') end,
--       on_error   = vim.notify,
--   })

local M = {}

local cfg = {
	base_url = "https://openrouter.ai/api/v1",
	api_key = nil,
	organization = nil,
	timeout = 30000, -- ms before vim.system kills curl
}

--- Configure the module (call once from plugin setup)
---@param opts table
function M.setup(opts)
	opts = opts or {}
	for k, v in pairs(opts) do
		cfg[k] = v or cfg[k]
	end
end

--- Internal: build curl header list
local function build_headers()
	local hdr = {
		"-H",
		"Content-Type: application/json",
		"-H",
		"Authorization: Bearer " .. (cfg.api_key or ""),
	}
	if cfg.organization then
		table.insert(hdr, "-H")
		table.insert(hdr, "OpenAI-Organization: " .. cfg.organization)
	end
	return hdr
end

--- Send a chat completion request.
---@param body table   -- full JSON payload per OpenAI docs
---@param cb   table   -- {on_chunk, on_complete, on_done, on_error}
---@return userdata    -- vim.system handle (for cancellation)
function M.chat(body, cb)
	cb = cb or {}
	if not cfg.api_key or cfg.api_key == "" then
		local msg = "[openai.lua] Missing API key (setup{api_key=} or $OPENAI_API_KEY)";
		(cb.on_error or vim.notify)(msg, vim.log.levels.ERROR)
		return
	end

	local payload = vim.json.encode(body)

	local cmd = {
		"curl",
		"-sS",
		"--no-buffer",
		"-X",
		"POST",
		cfg.base_url .. "/chat/completions",
	}
	vim.list_extend(cmd, build_headers())
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
				if cb.on_done then
					vim.schedule(cb.on_done)
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
		timeout = cfg.timeout,
		stdout = function(_, data)
			-- print("stdout:")
			-- print(data)
			if body.stream then
				handle_stream(data)
			else
				if data then
					stdout_acc[#stdout_acc + 1] = data
				end
			end
		end,
		stderr = function(_, data)
			-- print("error:")
			-- print(data)
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
