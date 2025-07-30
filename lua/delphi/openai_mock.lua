local M = {}

--- Configure the module (call once from plugin setup)
---@param opts table
function M.setup(opts) end

local uv = vim.uv

function M.chat(body, cb)
	cb = cb or {}
	local i, timer = 1, uv.new_timer()
	local new_text = [[
```
def fib(n: int, cache: dict[int, int] = defaultdict(int)):
    if n <= 1:
        return 1
    ret = fib(n - 2) + fib(n - 1)
    cache[n] = ret
    return ret
```
]]

	local function tick()
		if i > #new_text then
			if cb.on_chunk then
				cb.on_chunk(nil, true)
			end
			timer:stop()
			-- timer:close()
			return
		end
		cb.on_chunk({ choices = { { delta = { content = new_text:sub(i, i) } } } })
		cb.on_chunk({ choices = { { delta = { content = new_text:sub(i, i) } } } })
		i = i + 1
	end

	local function tick1()
		cb.on_chunk({ choices = { { delta = { content = new_text } } } })
		timer:stop()
	end

	timer:start(0, 1, vim.schedule_wrap(tick1)) -- 1 s interval
	return timer -- caller can :stop() to cancel
end
return M
