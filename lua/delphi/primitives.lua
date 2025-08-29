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

---Ensure <Plug>-style mapping for Chat send exists globally.
---@return nil
function P.apply_chat_plug_mappings()
	if vim.g.delphi_chat_plugs_applied then
		return
	end
	vim.g.delphi_chat_plugs_applied = true

	-- Normal mode: send chat (resolves context inside :Chat)
	vim.keymap.set("n", "<Plug>(DelphiChatSend)", function()
		local buf = vim.api.nvim_get_current_buf()
		if not vim.b[buf].is_delphi_chat then
			return
		end
		vim.cmd([[Chat]])
	end, { desc = "Delphi: send chat", silent = true })
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

---Check whether a string starts with a given prefix.
---@param str string
---@param prefix string
---@return boolean
local function starts_with(str, prefix)
	return str:sub(1, #prefix) == prefix
end

---Trim leading and trailing whitespace from a string.
---@param s string
---@return string
local function strip(s)
	return s:match("^%s*(.-)%s*$")
end

---Determine the role header of a chat line.
---@param line string Line from the chat buffer.
---@return "system"|"user"|"assistant"|nil role The detected role, or nil if no header is recognised.
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

---Parse YAML front-matter key/value pairs
---@param lines string[] Buffer lines to scan
---@return table<string,string|number> frontmatter  Flat table key → value
---@return integer      end_index   Index **after** --- closing line (0 if none)
local function parse_frontmatter_lines(lines)
	if not lines[1] or lines[1] ~= "---" then
		return {}, 0
	end
	local ret = {} --[[@type table<string,string|number>]]
	for i = 2, #lines do
		local l = lines[i]
		if l == "---" then
			return ret, i
		end
		local k, v = l:match("^%s*(%S+)%s*:%s*(.*)%s*$")
		if k and v then
			local num = tonumber(v)
			ret[k] = num or v
		end
	end
	return ret, #lines
end

---Remove leading (if any) front-matter delimited by ---
---@param lines string[]
---@return string[] lines Remaining lines **after** the closing ---
function P.strip_frontmatter(lines)
	local _, idx = parse_frontmatter_lines(lines)
	if idx == 0 then
		return lines
	end
	local res = {}
	local start = idx + 1
	if lines[start] == "" then
		start = start + 1
	end
	for i = start, #lines do
		res[#res + 1] = lines[i]
	end
	return res
end

---Read and parse YAML front-matter from a buffer or a ready-made list of lines
---@param buf_or_lines integer|string[] Either buffer number (0 = current) or pre-read lines
---@return table<string,string|number> frontmatter Flat table key → value
function P.parse_frontmatter(buf_or_lines)
	local lines
	if type(buf_or_lines) == "table" then
		lines = buf_or_lines
	else
		local buf = buf_or_lines or 0
		lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	end
	local fm = parse_frontmatter_lines(lines)
	return fm
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

---Scroll window(s) showing the buffer so the last User header is at top-of-window.
---@param buf integer|nil
---@return boolean did_scroll
function P.scroll_last_user_to_top(buf)
	buf = buf or 0
	if not vim.api.nvim_buf_is_valid(buf) then
		return false
	end
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	local target_lnum = nil --[[@type integer?]]
	for i = #lines, 1, -1 do
		if lines[i]:match("^%s*" .. vim.pesc(P.headers.user)) then
			target_lnum = i
			break
		end
	end
	if not target_lnum then
		return false
	end
	local did = false
	for _, win in ipairs(vim.api.nvim_list_wins()) do
		if vim.api.nvim_win_get_buf(win) == buf then
			did = true
			vim.api.nvim_win_call(win, function()
				local view = vim.fn.winsaveview()
				view.topline = target_lnum
				pcall(vim.fn.winrestview, view)
			end)
		end
	end
	return did
end

-- Read entire buffer into a single string
---@param buf integer
---@return string
function P.read_buf(buf)
	return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

function P.open_new_chat_buffer(system_prompt, model_name, temperature)
	vim.cmd("enew") -- new buffer, same window
	local buf = vim.api.nvim_get_current_buf()

	vim.bo.buftype, vim.bo.bufhidden, vim.bo.filetype = "nofile", "hide", "markdown"
	-- ▼ folding: one call, one liner ▼
	-- vim.wo.foldmethod = "expr"
	-- vim.wo.foldexpr = "v:lua.delphi_foldexpr(v:lnum)"

	local lines = {
		"---",
		string.format("model: %s", tostring(model_name or "")),
		string.format("temperature: %s", tostring(temperature or "")),
		"---",
		"",
		P.headers.system,
		system_prompt or "",
		"", -- spacer
		P.headers.user,
		"", -- where the user types
	}
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

	-- Enable cmp source for @-file mentions in this chat buffer, if available.
	local ok_cmp, cmp = pcall(require, "cmp")
	if ok_cmp then
		if type(P.ensure_cmp_source_registered) == "function" then
			P.ensure_cmp_source_registered()
		end
		local sources = cmp.get_config().sources or {}
		local has_delphi = false
		for _, s in ipairs(sources) do
			if s.name == "delphi_path" then
				has_delphi = true
				break
			end
		end
		if not has_delphi then
			sources = vim.list_extend({ { name = "delphi_path" } }, sources)
		end
		cmp.setup.buffer({ sources = sources })
	end

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

	-- Enable cmp source for @-file mentions in this chat buffer, if available
	local ok_cmp, cmp = pcall(require, "cmp")
	if ok_cmp then
		if type(P.ensure_cmp_source_registered) == "function" then
			P.ensure_cmp_source_registered()
		end
		local sources = cmp.get_config().sources or {}
		local has_delphi = false
		for _, s in ipairs(sources) do
			if s.name == "delphi_path" then
				has_delphi = true
				break
			end
		end
		if not has_delphi then
			sources = vim.list_extend({ { name = "delphi_path" } }, sources)
		end
		cmp.setup.buffer({ sources = sources })
	end

	P.set_cursor_to_user(buf)
	return buf
end

---Return the first loaded chat buffer, if any
---@return integer|nil buf
function P.find_chat_buffer()
	for _, b in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_loaded(b) and vim.b[b].is_delphi_chat then
			return b
		end
	end
	return nil
end

---Create a new window split
---@param dir 'horizontal'|'vertical'
---@return integer win
function P.new_split(dir)
	if dir == "vertical" then
		vim.api.nvim_cmd({ cmd = "vsplit" }, {})
	else
		vim.api.nvim_cmd({ cmd = "split" }, {})
	end
	return vim.api.nvim_get_current_win()
end

---Focus the given buffer in the current window
---@param buf integer
function P.set_current_buf(buf)
	vim.api.nvim_set_current_buf(buf)
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
---@return { path:string, preview:string, text:string }[]
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
				table.insert(res, { path = p, preview = preview, text = text })
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

-- plenary.popup is required lazily inside P.show_popup to avoid loading
-- plenary at startup/module import time.

---Show a centered popup that accepts multiline input.
---Accept with <CR> in Normal mode. Cancel with <Esc><Esc>.
---@param label string
---@param cb fun(text:string)|nil
---@return integer win
function P.show_popup(label, cb)
	local popup = require("plenary.popup")
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

	-- Use a normal scratch buffer so newlines are inserted naturally.
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].filetype = "markdown"

	-- Submit helper
	local function submit()
		if not vim.api.nvim_win_is_valid(win) then
			return
		end
		local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
		vim.api.nvim_win_close(win, true)
		cb(vim.trim(table.concat(lines, "\n")))
	end

	-- Keymaps: cancel with <Esc> in Normal mode; submit with <CR> in Normal mode
	vim.keymap.set(
		"n",
		"<ESC>",
		"<Plug>(DelphiPromptCancel)",
		{ buffer = buf, noremap = true, silent = true, desc = "Delphi: cancel prompt" }
	)
	vim.keymap.set("n", "<Plug>(DelphiPromptCancel)", function()
		if vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_close(win, true)
		end
		cb("")
	end, { buffer = buf, noremap = true, silent = true, desc = "Delphi: cancel prompt" })
	vim.keymap.set("n", "<CR>", function()
		submit()
	end, { buffer = buf, noremap = true, silent = true, desc = "Delphi: submit prompt" })

	vim.schedule(function()
		if vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_set_current_win(win)
			vim.cmd("startinsert!")
		end
	end)

	return win
end

local ghost_ns = vim.api.nvim_create_namespace("delphi_ghost_diff")

---Start a ghost diff overlay for live preview while streaming new content.
---@param buf integer            Buffer handle
---@param start_lnum integer     1-based, inclusive start line of selection/insert
---@param end_lnum integer       1-based, inclusive end line of selection/insert
---@param left_lines string[]    Original selected lines (empty for insert)
---@return { push: fun(tok:string), accept: fun(), reject: fun() }
function P.start_ghost_diff(buf, start_lnum, end_lnum, left_lines)
	local Differ = require("delphi.patience").Differ
	local d = Differ:new()
	local right_text = ""
	local is_insert = (start_lnum == end_lnum)

	---Render the diff preview. For insert-at (single-line), render as a simple
	---append preview without running a diff to avoid noisy overlays.
	---@param lines string[]  -- difflib-style lines when not insert mode
	local function render(lines)
		-- There's probably a way to optimize this
		vim.api.nvim_buf_clear_namespace(buf, ghost_ns, 0, -1)

		local row = start_lnum - 1

		if is_insert then
			-- Simple insert preview: show all new lines as additions at the insert point
			local right_lines = vim.split(right_text, "\n", { plain = true, trimempty = false })
			local virt_lines = {}
			for _, rl in ipairs(right_lines) do
				virt_lines[#virt_lines + 1] = { { rl, "DiffAdd" } }
			end
			if #virt_lines > 0 then
				vim.api.nvim_buf_set_extmark(buf, ghost_ns, row, 0, {
					virt_lines = virt_lines,
					virt_lines_above = false,
				})
			end
			return
		end

		-- To maintain correct visual order of added lines, render contiguous
		-- runs of '+' as a single virt_lines block instead of one extmark per line.
		local pending_adds = {}
		local function flush_adds()
			if #pending_adds == 0 then
				return
			end
			local virt_lines = {}
			for _, t in ipairs(pending_adds) do
				virt_lines[#virt_lines + 1] = { { t, "DiffAdd" } }
			end
			vim.api.nvim_buf_set_extmark(buf, ghost_ns, row, 0, {
				virt_lines = virt_lines,
				virt_lines_above = false,
			})
			pending_adds = {}
		end

		for _, l in ipairs(lines) do
			local tag = l:sub(1, 1)
			local text = l:sub(3)
			if tag == " " then
				flush_adds()
				row = row + 1
			elseif tag == "-" then
				flush_adds()
				vim.api.nvim_buf_set_extmark(buf, ghost_ns, row, 0, {
					virt_text = { { text, "DiffDelete" } },
					virt_text_pos = "overlay",
				})
				row = row + 1
			elseif tag == "+" then
				pending_adds[#pending_adds + 1] = text
			end
		end
		flush_adds()
	end

	return {
		push = function(tok)
			right_text = right_text .. tok
			if is_insert then
				-- No diffing; just render the insertion preview
				render({})
			else
				local right_lines = vim.split(right_text, "\n", { plain = true, trimempty = false })
				render(d:compare(left_lines, right_lines))
			end
		end,
		accept = function()
			local lines = vim.split(right_text, "\n", { plain = true, trimempty = true })
			pcall(vim.cmd, "undojoin")
			if is_insert then
				-- Insert without replacing existing content
				vim.api.nvim_buf_set_lines(buf, start_lnum - 1, start_lnum - 1, false, lines)
			else
				-- Replace selection with rewritten content
				vim.api.nvim_buf_set_lines(buf, start_lnum - 1, end_lnum, false, lines)
			end
			vim.api.nvim_buf_clear_namespace(buf, ghost_ns, 0, -1)
		end,
		reject = function()
			vim.api.nvim_buf_clear_namespace(buf, ghost_ns, 0, -1)
		end,
	}
end

---Ensure <Plug>-style mappings for Rewrite/Insert exist.
---@return nil
function P.apply_rewrite_plug_mappings()
	if vim.g.delphi_rewrite_plugs_applied then
		return
	end
	vim.g.delphi_rewrite_plugs_applied = true

	-- Visual/Select: rewrite the current selection
	vim.keymap.set({ "x", "s" }, "<Plug>(DelphiRewriteSelection)", ":<C-u>Rewrite<CR>", {
		desc = "Delphi: rewrite selection",
		silent = true,
	})

	-- Normal/Insert: insert at cursor (single-line mode)
	vim.keymap.set("n", "<Plug>(DelphiInsertAtCursor)", ":Rewrite<CR>", {
		desc = "Delphi: insert at cursor",
		silent = true,
	})
	vim.keymap.set("i", "<Plug>(DelphiInsertAtCursor)", "<C-o>:Rewrite<CR>", {
		desc = "Delphi: insert at cursor",
		silent = true,
	})
end

---Register the cmp source for delphi path completion once, on demand.
---@return nil
function P.ensure_cmp_source_registered()
	if vim.g.delphi_cmp_registered then
		return
	end
	local ok_cmp, cmp = pcall(require, "cmp")
	if not ok_cmp then
		return
	end
	local ok_src, src = pcall(require, "delphi.cmp_source")
	if not ok_src then
		return
	end
	cmp.register_source("delphi_path", src)
	vim.g.delphi_cmp_registered = true
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
	local cur_lines_filtered = filter_empty(P.strip_frontmatter(cur_lines))
	local stored_filtered = filter_empty(P.strip_frontmatter(meta.stored_lines or {}))
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

---Adds `<rewrite_this>...</rewrite_this>` or `<insert_here></insert_here>` markers.
---@param lines string[]  -- original buffer lines
---@param start_lnum integer -- 1-based, inclusive
---@param end_lnum integer   -- 1-based, inclusive
---@return string[]          -- copy with markers inserted
local function add_rewrite_markers(lines, start_lnum, end_lnum)
	local ret = {}

	for i = 1, start_lnum - 1 do
		ret[#ret + 1] = lines[i]
	end

	if start_lnum == end_lnum then
		ret[#ret + 1] = "<insert_here></insert_here>"
		for i = start_lnum, #lines do
			ret[#ret + 1] = lines[i]
		end
	else
		ret[#ret + 1] = "<rewrite_this>"
		for i = start_lnum, end_lnum do
			ret[#ret + 1] = lines[i]
		end
		ret[#ret + 1] = "</rewrite_this>"
		for i = end_lnum + 1, #lines do
			ret[#ret + 1] = lines[i]
		end
	end

	return ret
end
---Build a rewrite prompt for a document range
---@param buf integer buffer id
---@param start_lnum integer 1-based start line (inclusive)
---@param end_lnum integer 1-based end line (inclusive)
---@param prompt string user's prompt describing the desired change
---@return string prompt built for the rewrite
function P.build_rewrite_prompt(buf, start_lnum, end_lnum, prompt)
	local ft = vim.bo[buf].filetype
	local content_type
	if ft == "markdown" or ft == "text" or ft == nil then
		content_type = "text"
	else
		content_type = "code"
	end
	-- TODO: put a length limit
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	local doc_w_markers = add_rewrite_markers(lines, start_lnum, end_lnum)
	local rewrite_lines = vim.api.nvim_buf_get_lines(buf, start_lnum - 1, end_lnum, false)

	return require("delphi.rewrite").build_prompt({
		content_type = content_type,
		language_name = ft,
		document_content = table.concat(doc_w_markers, "\n"),
		is_insert = start_lnum == end_lnum,
		is_truncated = false,
		user_prompt = prompt,
		rewrite_section = table.concat(rewrite_lines, "\n"),
	})
end

return P
