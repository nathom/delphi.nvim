-- primitives.lua -------------------------------------------------------------
-- Minimal helpers for chat-buffer manipulation.  No extra dependencies.

local P = {}

local function starts_with(str, prefix)
	return str:sub(1, #prefix) == prefix
end

local function strip(s)
	return s:match("^%s*(.-)%s*$")
end

local function get_header(line)
	local hdr = nil
	if starts_with(line, "System") then
		hdr = "system"
	elseif starts_with(line, "User") then
		hdr = "user"
	elseif starts_with(line, "Assistant") then
		hdr = "assistant"
	end
	return hdr
end

function P.foldexpr(lnum)
	local line = vim.api.nvim_buf_get_lines(0, lnum - 1, lnum, false)[1] or ""
	if get_header(line) ~= nil then
		return 1
	end
	local prev_line = vim.api.nvim_buf_get_lines(0, lnum - 2, lnum - 1, false)[1] or ""
	if get_header(prev_line) ~= nil then
		return ">"
	end
	return "=" -- inside a turn
end
_G.myllm_foldexpr = P.foldexpr -- expose for 'foldexpr'

-- improved block parser ------------------------------------------------------
---@param input string
---@return table[]  -- { {role='user', content='…'}, … }
function P.to_messages(input)
	local msgs, role, body = {}, nil, {}

	local function push()
		if role and #body > 0 then
			local content = strip(table.concat(body, "\n"))
			if #content > 0 then
				table.insert(msgs, { role = role, content = content })
			end
		end
		body = {}
	end

	for line in input:gmatch("[^\n]*") do
		-- pure header line (no body on same line)
		local hdr = get_header(line)
		if hdr then
			push()
			role = hdr:lower()
		else
			table.insert(body, line)
		end
	end
	push() -- flush last block
	return msgs
end

-------------------------------------------------------------------------------
-- 2. Append one line to a buffer (at EOF, no newline added)
-------------------------------------------------------------------------------
---@param buf integer
---@param line string
function P.append_line_to_buf(buf, line)
	local last = vim.api.nvim_buf_line_count(buf)
	vim.api.nvim_buf_set_lines(buf, last, last, false, { line })
end

function P.append_chunk_to_buf(buf, chunk)
	buf = buf or 0
	if not vim.api.nvim_buf_is_valid(buf) then
		error(("append_chunk_to_buf: invalid buffer %s"):format(tostring(buf)))
	end

	-- Current trailing line to be extended.
	local line_count = vim.api.nvim_buf_line_count(buf)
	local last_idx = line_count - 1 -- zero-based
	local last_line = vim.api.nvim_buf_get_lines(buf, last_idx, last_idx + 1, false)[1] or ""

	-- Split the incoming text *keeping* empty pieces so we can tell whether it
	-- ended in “\n”.
	local parts = vim.split(chunk, "\n", { plain = true, trimempty = false })

	---------------------------------------------------------------------------
	-- 1. Extend the current last line with the first fragment.
	---------------------------------------------------------------------------
	vim.api.nvim_buf_set_lines(buf, last_idx, last_idx + 1, false, { last_line .. parts[1] })

	---------------------------------------------------------------------------
	-- 2. Everything after the first “\n” becomes new lines.
	---------------------------------------------------------------------------
	if #parts > 1 then
		-- unpack is available in LuaJIT / Luau used by Neovim
		vim.api.nvim_buf_set_lines(buf, -1, -1, false, { unpack(parts, 2) })
	end
end

-------------------------------------------------------------------------------
-- 3. Move cursor to the last “User:” prompt in the given buffer
-------------------------------------------------------------------------------
---@param buf integer
function P.set_cursor_to_user(buf)
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	for i = #lines, 1, -1 do
		if lines[i]:match("^%s*User%s*:") then
			for _, win in ipairs(vim.api.nvim_list_wins()) do
				if vim.api.nvim_win_get_buf(win) == buf then
					vim.api.nvim_set_current_win(win)
					vim.api.nvim_win_set_cursor(win, { i + 1, 0 })
					return
				end
			end
		end
	end
end

-------------------------------------------------------------------------------
-- 4. Read entire buffer into a single string
-------------------------------------------------------------------------------
---@param buf integer
---@return string
function P.read_buf(buf)
	return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

function P.open_new_chat_buffer(system_prompt)
	vim.cmd("enew") -- new buffer, same window
	local buf = vim.api.nvim_get_current_buf()

	-- make it scratch-like
	vim.bo.buftype, vim.bo.bufhidden, vim.bo.filetype = "nofile", "hide", "markdown"
	-- ▼ folding: one call, one liner ▼
	-- vim.wo.foldmethod = "expr"
	-- vim.wo.foldexpr = "v:lua.myllm_foldexpr(v:lnum)"

	local lines = {
		"System:",
		system_prompt or "",
		"", -- spacer
		"User:",
		"", -- where the user types
	}
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

	P.set_cursor_to_user(buf) -- jump to User prompt
	vim.cmd("startinsert")
	return buf
end

---------------------------------------------------------------------------
-- 5. Visual-selection helpers --------------------------------------------
---------------------------------------------------------------------------

---Return current visual selection (or current line if none).
--- @param buf integer|nil
--- @return table  -- { lines = {...}, start_lnum = n, end_lnum = n }
function P.get_visual_selection(buf)
	buf = buf or 0
	local s = vim.fn.getpos("'<")[2] -- line numbers
	local e = vim.fn.getpos("'>")[2]
	if s == 0 or e == 0 then -- no visual marks → use cursor line
		s, e = unpack(vim.api.nvim_win_get_cursor(0))
		e = s
	end
	if s > e then
		s, e = e, s
	end -- make ascending
	local lines = vim.api.nvim_buf_get_lines(buf, s - 1, e, false)
	return { lines = lines, start_lnum = s, end_lnum = e }
end

---------------------------------------------------------------------------
-- 8. Popup prompt (async, Plenary) -----------------------------------------
-- Requires plenary.nvim (Popup module).
--
--  P.show_popup(label, callback) → win_id
--
--  • Opens a centred floating window headed by `label`.
--  • User types below the label.
--  • <CR>   → close popup, pass trimmed text to `callback(text)`.
--  • <Esc><Esc> → close popup, pass empty string to `callback("")`.
--  • Returns the **window id** so the caller may inspect/close it if needed.
--
--  Non-blocking: execution continues immediately after the call; the user
--  input is delivered solely via the callback.
---------------------------------------------------------------------------

local popup = require("plenary.popup")

function P.show_popup(label, cb)
	cb = cb or function() end

	local width = math.floor(vim.o.columns * 0.60)
	local height = 5

	-- ① create popup → win_id
	local win = popup.create({ "" }, {
		title = label,
		enter = true,
		line = math.floor((vim.o.lines - height) / 2),
		col = math.floor((vim.o.columns - width) / 2),
		minheight = height,
		minwidth = width,
		borderchars = { "─", "│", "─", "│", "╭", "╮", "╯", "╰" },
	}) -- win is **window id**

	-- ② grab the (scratch) buffer that plenary just made
	local buf = vim.api.nvim_win_get_buf(win)

	-- ③ prompt-style: <CR> submits, <Esc><Esc> cancels
	vim.bo[buf].buftype = "prompt"
	vim.fn.prompt_setprompt(buf, "› ")
	vim.fn.prompt_setcallback(buf, function(text)
		vim.api.nvim_win_close(win, true)
		cb(vim.trim(text))
	end)
	vim.keymap.set({ "n", "i" }, "<Esc><Esc>", function()
		vim.api.nvim_win_close(win, true)
		cb("")
	end, { buffer = buf, noremap = true, silent = true })

	return win
end

local diff_ns = vim.api.nvim_create_namespace("myllm_inline_diff")

function P.start_inline_diff(buf, start_lnum, end_lnum, left_lines)
	local ud = require("llm-nvim.unidiff")
	local differ = ud.Differ and ud.Differ.new or require("llm-nvim.unidiff").new
	local d = differ(table.concat(left_lines, "\n"))
	local orig = vim.deepcopy(left_lines) -- for reject()
	local cur_end = end_lnum

	local function render(lines)
		-- Replace current block with `lines`; extend/shrink as needed.
		vim.api.nvim_buf_set_lines(buf, start_lnum - 1, cur_end, false, lines)
		-- Clear & re-add extmarks
		vim.api.nvim_buf_clear_namespace(buf, diff_ns, start_lnum - 1, start_lnum - 1 + #lines)
		for i, l in ipairs(lines) do
			local tag = l:sub(1, 1)
			if tag == "+" or tag == "-" then
				local hl = (tag == "+") and "DiffAdd" or "DiffDelete"
				vim.api.nvim_buf_set_extmark(
					buf,
					diff_ns,
					start_lnum + i - 2,
					0,
					{ virt_text = { { tag, hl } }, virt_text_pos = "overlay", hl_group = hl }
				)
			end
		end
		cur_end = start_lnum + #lines - 1
	end

	render(d:lines()) -- initial identical diff

	return {
		push = function(tok)
			render(d:update(tok))
		end,
		accept = function()
			vim.api.nvim_buf_set_lines(
				buf,
				start_lnum - 1,
				cur_end,
				false,
				vim.split(d.right_text, "\n", { plain = true, trimempty = false })
			)
			vim.api.nvim_buf_clear_namespace(buf, diff_ns, start_lnum - 1, cur_end)
		end,
		reject = function()
			vim.api.nvim_buf_set_lines(buf, start_lnum - 1, cur_end, false, orig)
			vim.api.nvim_buf_clear_namespace(buf, diff_ns, start_lnum - 1, cur_end)
		end,
	}
end

return P
