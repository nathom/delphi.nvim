local P = {}

-- Header strings used in chat buffers
P.headers = {
	system = "System:",
	user = "User:",
	assistant = "Assistant:",
}

---Override the default chat headers
---@param hdrs {system?:string,user?:string,assistant?:string}|nil
function P.set_headers(hdrs)
	if not hdrs then
		return
	end
	for k, v in pairs(hdrs) do
		if type(v) == "string" then
			P.headers[k] = v
		end
	end
end

---Fill in a template string
---@param str string
---@param env table
---@return string
function P.template(str, env)
	return (
		str:gsub("{{(.-)}}", function(key)
			if env[key] then
				return env[key]
			else
				vim.notify("delphi.nvim: invalid variable '" .. key .. "' in template string", vim.log.levels.WARN)
				return "{{" .. key .. "}}"
			end
		end)
	)
end

local function starts_with(str, prefix)
	return str:sub(1, #prefix) == prefix
end

local function strip(s)
	return s:match("^%s*(.-)%s*$")
end

local function get_header(line)
	local hdr = nil
	if starts_with(line, P.headers.system) then
		hdr = "system"
	elseif starts_with(line, P.headers.user) then
		hdr = "user"
	elseif starts_with(line, P.headers.assistant) then
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
_G.delphi_foldexpr = P.foldexpr

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

---@param buf integer
---@param line string
function P.append_line_to_buf(buf, line)
	local last = vim.api.nvim_buf_line_count(buf)
	vim.api.nvim_buf_set_lines(buf, last, last, false, { line })
end

function P.append_chunk_to_buf(buf, chunk)
	if not chunk then
		return
	end
	buf = buf or 0
	if not vim.api.nvim_buf_is_valid(buf) then
		error(("append_chunk_to_buf: invalid buffer %s"):format(tostring(buf)))
	end

	local line_count = vim.api.nvim_buf_line_count(buf)
	local last_idx = line_count - 1
	local last_line = vim.api.nvim_buf_get_lines(buf, last_idx, last_idx + 1, false)[1] or ""

	local parts = vim.split(chunk, "\n", { plain = true, trimempty = false })

	vim.api.nvim_buf_set_lines(buf, last_idx, last_idx + 1, false, { last_line .. parts[1] })

	if #parts > 1 then
		vim.api.nvim_buf_set_lines(buf, -1, -1, false, { unpack(parts, 2) })
	end
end

-- Move cursor to the last “User:” prompt in the given buffer
---@param buf integer
function P.set_cursor_to_user(buf)
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	for i = #lines, 1, -1 do
		if lines[i]:match("^%s*" .. vim.pesc(P.headers.user)) then
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

-- Read entire buffer into a single string
---@param buf integer
---@return string
function P.read_buf(buf)
	return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

function P.open_new_chat_buffer(system_prompt)
	vim.cmd("enew") -- new buffer, same window
	local buf = vim.api.nvim_get_current_buf()

	vim.bo.buftype, vim.bo.bufhidden, vim.bo.filetype = "nofile", "hide", "markdown"
	-- ▼ folding: one call, one liner ▼
	-- vim.wo.foldmethod = "expr"
	-- vim.wo.foldexpr = "v:lua.delphi_foldexpr(v:lnum)"

	local lines = {
		P.headers.system,
		system_prompt or "",
		"", -- spacer
		P.headers.user,
		"", -- where the user types
	}
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

	P.set_cursor_to_user(buf) -- jump to User prompt
	vim.cmd("startinsert")
	return buf
end

-- Persistent chat helpers ----------------------------------------------------

---Return directory for chat transcripts (created on demand)
---@return string
function P.chat_data_dir()
	local dir = vim.fn.stdpath("data") .. "/delphi.nvim/chats"
	if vim.fn.isdirectory(dir) == 0 then
		vim.fn.mkdir(dir, "p")
	end
	return dir
end

---Generate a path for a new chat transcript
---@return string
function P.next_chat_path()
	local dir = P.chat_data_dir()
	local files = vim.fn.readdir(dir)
	local max = -1
	for _, f in ipairs(files) do
		local n = tonumber(f:match("^chat_(%d+)%.md$"))
		if n and n > max then
			max = n
		end
	end
	return string.format("%s/chat_%d.md", dir, max + 1)
end

---Open a chat from a file path
---@param path string
---@return integer buf
function P.open_chat_file(path)
	local ok, lines = pcall(vim.fn.readfile, path)
	if not ok then
		lines = {}
	end
	vim.cmd("enew")
	local buf = vim.api.nvim_get_current_buf()
	vim.bo.buftype, vim.bo.bufhidden, vim.bo.filetype = "nofile", "hide", "markdown"
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.b.is_delphi_chat = true
	vim.b.delphi_chat_path = path
	vim.b.delphi_meta_path = path:gsub("%.md$", "_meta.json")
	P.set_cursor_to_user(buf)
	return buf
end

---Save a chat buffer to its associated path
---@param buf integer|nil
---@param path string|nil
function P.save_chat(buf, path)
	buf = buf or 0
	path = path or vim.b[buf].delphi_chat_path
	if not path or path == "" then
		return
	end
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	vim.fn.writefile(lines, path)
end

---List available chats
---@return { path:string, preview:string }[]
function P.list_chats()
	local dir = P.chat_data_dir()
	local files = vim.fn.readdir(dir)
	table.sort(files, function(a, b)
		local na = tonumber(a:match("^chat_(%d+)")) or 0
		local nb = tonumber(b:match("^chat_(%d+)")) or 0
		return na < nb
	end)

	local res = {}
	for _, f in ipairs(files) do
		if f:match("^chat_%d+%.md$") then
			local p = dir .. "/" .. f
			local ok, lines = pcall(vim.fn.readfile, p)
			if ok then
				local text = table.concat(lines, "\n")
				local msgs = P.to_messages(text)
				local preview = ""
				for _, m in ipairs(msgs) do
					if m.role == "user" then
						preview = m.content
						break
					end
				end
				preview = preview:gsub("\n", " "):gsub("%.%s.*", ".")
				if #preview > 40 then
					preview = preview:sub(1, 37) .. "..."
				end
				table.insert(res, { path = p, preview = preview })
			end
		end
	end
	return res
end

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

local popup = require("plenary.popup")

function P.show_popup(label, cb)
	cb = cb or function() end

	local width = math.floor(vim.o.columns * 0.60)
	local height = 5
	local win = popup.create({ "" }, {
		title = label,
		enter = true,
		line = math.floor((vim.o.lines - height) / 2),
		col = math.floor((vim.o.columns - width) / 2),
		minheight = height,
		minwidth = width,
		borderchars = { "─", "│", "─", "│", "╭", "╮", "╯", "╰" },
	})

	local buf = vim.api.nvim_win_get_buf(win)

	vim.bo[buf].buftype = "prompt"
	vim.fn.prompt_setprompt(buf, "› ")
	vim.fn.prompt_setcallback(buf, function(text)
		vim.api.nvim_win_close(win, true)
		cb(vim.trim(text))
	end)
	vim.schedule(function()
		if vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_set_current_win(win)
			vim.cmd("startinsert!")
		end
	end)
	vim.keymap.set({ "n", "i" }, "<Esc><Esc>", function()
		vim.api.nvim_win_close(win, true)
		cb("")
	end, { buffer = buf, noremap = true, silent = true })

	return win
end

local diff_ns = vim.api.nvim_create_namespace("delphi_inline_diff")

function P.start_inline_diff(buf, start_lnum, end_lnum, left_lines)
	local Differ = require("delphi.patience").Differ
	local d = Differ:new()
	local right_text = ""
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
					{ virt_text = { { l, hl } }, virt_text_pos = "overlay", hl_group = hl, invalidate = true }
				)
			end
		end
		cur_end = start_lnum + #lines - 1
	end

	return {
		push = function(tok)
			right_text = right_text .. tok
			local right_lines = vim.split(right_text, "\n", { plain = true, trimempty = false })
			render(d:compare(left_lines, right_lines))
		end,
		accept = function()
			vim.api.nvim_buf_set_lines(
				buf,
				start_lnum - 1,
				cur_end,
				false,
				vim.split(right_text, "\n", { plain = true, trimempty = false })
			)
			vim.api.nvim_buf_clear_namespace(buf, diff_ns, start_lnum - 1, cur_end)
		end,
		reject = function()
			vim.api.nvim_buf_set_lines(buf, start_lnum - 1, cur_end, false, orig)
			vim.api.nvim_buf_clear_namespace(buf, diff_ns, start_lnum - 1, cur_end)
		end,
	}
end

-- chat metadata helpers ------------------------------------------------------

function P.chat_meta_path(chat_path)
	return chat_path:gsub("%.md$", "_meta.json")
end

function P.read_chat_meta(chat_path)
	local meta_path = P.chat_meta_path(chat_path)
	local ok, lines = pcall(vim.fn.readfile, meta_path)
	if not ok then
		return { tags = {}, stored_lines = {}, invalid = false }
	end
	local ok2, decoded = pcall(vim.json.decode, table.concat(lines, "\n"), { luanil = { object = true, array = true } })
	if not ok2 or type(decoded) ~= "table" then
		decoded = {}
	end
	decoded.tags = decoded.tags or {}
	decoded.stored_lines = decoded.stored_lines or {}
	decoded.invalid = decoded.invalid or false
	return decoded
end

function P.write_chat_meta(chat_path, meta)
	local meta_path = P.chat_meta_path(chat_path)
	vim.fn.writefile({ vim.json.encode(meta) }, meta_path)
end

function P.reset_meta(chat_path)
	---@class Metadata
	local blank_meta = {
		invalid = false,
		stored_lines = {},
		tags = {},
	}
	local meta_path = P.chat_meta_path(chat_path)
	vim.fn.writefile({ vim.json.encode(blank_meta) }, meta_path)
end

function P.invalidate_meta(buf)
	local path = vim.b[buf].delphi_chat_path
	if not path then
		return
	end
	local meta = P.read_chat_meta(path)
	if meta.invalid then
		return
	end
	meta.invalid = true
	P.write_chat_meta(path, meta)
	vim.notify("delphi.nvim: chat metadata invalidated. Press 'u' to undo.", vim.log.levels.WARN)
	local ns = vim.api.nvim_create_namespace("delphi_meta_undo")
	vim.on_key(function(ch)
		vim.on_key(nil, ns)
		if ch == "u" then
			vim.api.nvim_buf_set_lines(buf, 0, -1, false, meta.stored_lines or {})
			meta.invalid = false
			P.write_chat_meta(path, meta)
		end
	end, ns)
end

---@class Metadata
---@field stored_lines string[]
---@field tags table<string, string[]>
---@field invalid boolean

---@class Message
---@field role "system" | "user" | "assistant"
---@field content string

---Resolve tags in messages
---@param meta Metadata
---@param messages Message[]
---@return Metadata, Message[]
function P.resolve_tags(meta, messages)
	local tag_counts = {}
	local new_messages = {}
	for _, msg in ipairs(messages) do
		local tags_in_msg = {}
		for tag in msg.content:gmatch("@(%S+)") do
			tag_counts[tag] = (tag_counts[tag] or 0) + 1
			local idx = tag_counts[tag]
			meta.tags[tag] = meta.tags[tag] or {}
			local content = meta.tags[tag][idx]
			if not content then
				local resolved = vim.fn.fnamemodify(tag, ":p")
				local ok, lines = pcall(vim.fn.readfile, resolved)
				if ok then
					content = table.concat(lines, "\n")
				else
					content = ""
				end
				meta.tags[tag][idx] = content
			end
			table.insert(tags_in_msg, { path = tag, content = content })
		end
		if #tags_in_msg > 0 then
			local prompt_lines = {}
			table.insert(prompt_lines, "<tagged_files>")
			for _, t in ipairs(tags_in_msg) do
				local ext = t.path:match("%.([%w_]+)$") or ""
				table.insert(prompt_lines, string.format("```%s %s\n%s\n```", ext, t.path, t.content))
			end
			table.insert(prompt_lines, "</tagged_files>")
			table.insert(prompt_lines, msg.content)
			table.insert(new_messages, { content = table.concat(prompt_lines, "\n"), role = msg.role })
		else
			table.insert(new_messages, msg)
		end
	end
	return meta, new_messages
end

local function filter_empty(tbl)
	local ret = {}
	for _, v in ipairs(tbl) do
		if v ~= "" then
			table.insert(ret, v)
		end
	end
	return ret
end

---@param cur_lines string[]
---@param meta Metadata
---@return boolean
function P.chat_invalidated(cur_lines, meta)
	local cur_lines_filtered = filter_empty(cur_lines)
	local stored_filtered = filter_empty(meta.stored_lines or {})
	if meta.invalid then
		return true
	end
	for i = 1, #stored_filtered do
		if cur_lines_filtered[i] ~= stored_filtered[i] then
			return true
		end
	end
	return false
end

return P
