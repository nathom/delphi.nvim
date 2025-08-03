local P = {}

local branch_ns = vim.api.nvim_create_namespace("delphi_branches")
local graph_ns = vim.api.nvim_create_namespace("delphi_branch_graph")

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

	P.set_cursor_to_user(buf) -- jump to User prompt
	vim.cmd("startinsert")
	P.render_branch_graph(buf)
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
	local meta = P.read_chat_meta(path)
	P.render_branch_links(buf, meta)
	P.render_branch_graph(buf)
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

local ghost_ns = vim.api.nvim_create_namespace("delphi_ghost_diff")

function P.start_ghost_diff(buf, start_lnum, end_lnum, left_lines)
	local Differ = require("delphi.patience").Differ
	local d = Differ:new()
	local right_text = ""

	local function render(lines)
		-- There's probably a way to optimize this
		vim.api.nvim_buf_clear_namespace(buf, ghost_ns, 0, -1)

		local row = start_lnum - 1
		for _, l in ipairs(lines) do
			local tag = l:sub(1, 1)
			local text = l:sub(3)
			if tag == " " then
				row = row + 1
			elseif tag == "-" then
				vim.api.nvim_buf_set_extmark(buf, ghost_ns, row, 0, {
					virt_text = { { text, "DiffDelete" } },
					virt_text_pos = "overlay",
					hl_mode = "combine",
				})
				row = row + 1
			elseif tag == "+" then
				vim.api.nvim_buf_set_extmark(buf, ghost_ns, row, 0, {
					virt_lines = { { { text, "DiffAdd" } } },
					virt_lines_above = true,
				})
			end
		end
	end

	return {
		push = function(tok)
			right_text = right_text .. tok
			local right_lines = vim.split(right_text, "\n", { plain = true, trimempty = false })
			render(d:compare(left_lines, right_lines))
		end,
		accept = function()
			local lines = vim.split(right_text, "\n", { plain = true, trimempty = true })
			pcall(vim.cmd, "undojoin")
			vim.api.nvim_buf_set_lines(buf, start_lnum - 1, end_lnum, false, lines)
			vim.api.nvim_buf_clear_namespace(buf, ghost_ns, 0, -1)
		end,
		reject = function()
			vim.api.nvim_buf_clear_namespace(buf, ghost_ns, 0, -1)
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
		return { tags = {}, stored_lines = {}, invalid = false, parent = nil, children = {} }
	end
	local ok2, decoded = pcall(vim.json.decode, table.concat(lines, "\n"), { luanil = { object = true, array = true } })
	if not ok2 or type(decoded) ~= "table" then
		decoded = {}
	end
	decoded.tags = decoded.tags or {}
	decoded.stored_lines = decoded.stored_lines or {}
	decoded.invalid = decoded.invalid or false
	decoded.parent = decoded.parent
	decoded.children = decoded.children or {}
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
		parent = nil,
		children = {},
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

---@class BranchRef
---@field path string
---@field lnum integer

---@class Metadata
---@field stored_lines string[]
---@field tags table<string, string[]>
---@field invalid boolean
---@field parent string|nil
---@field children BranchRef[]

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

---Render branch links for a chat buffer
---@param buf integer
---@param meta Metadata
function P.render_branch_links(buf, meta)
	vim.api.nvim_buf_clear_namespace(buf, branch_ns, 0, -1)
	if meta.parent then
		local name = vim.fn.fnamemodify(meta.parent, ":t")
		vim.api.nvim_buf_set_extmark(buf, branch_ns, 0, 0, {
			virt_text = { { "← " .. name, "Comment" } },
			virt_text_pos = "eol",
		})
	end
	for _, child in ipairs(meta.children or {}) do
		local name = vim.fn.fnamemodify(child.path, ":t")
		vim.api.nvim_buf_set_extmark(buf, branch_ns, (child.lnum or 1) - 1, 0, {
			virt_text = { { "↳ " .. name, "Comment" } },
			virt_text_pos = "eol",
		})
	end
end

---Fork the current chat buffer at the cursor line
---@param buf integer|nil
---@return integer|nil new_buf
function P.fork_chat(buf)
	buf = buf or 0
	local path = vim.b[buf].delphi_chat_path
	if not path then
		return nil
	end
	local lnum = vim.api.nvim_win_get_cursor(0)[1]
	local lines = vim.api.nvim_buf_get_lines(buf, 0, lnum, false)
	local child_path = P.next_chat_path()
	vim.fn.writefile(lines, child_path)
	local child_meta = P.read_chat_meta(child_path)
	child_meta.parent = path
	child_meta.stored_lines = lines
	P.write_chat_meta(child_path, child_meta)
	local meta = P.read_chat_meta(path)
	meta.children = meta.children or {}
	table.insert(meta.children, { path = child_path, lnum = lnum })
	P.write_chat_meta(path, meta)
	P.render_branch_links(buf, meta)
	local new_buf = P.open_chat_file(child_path)
	P.render_branch_links(new_buf, child_meta)
	P.render_branch_graph(new_buf)
	return new_buf
end

---Create a branch when chat history diverges
---@param buf integer
---@param meta Metadata
---@return Metadata
function P.retroactive_branch(buf, meta)
	local path = vim.b[buf].delphi_chat_path
	if not path then
		return meta
	end
	local cur_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	vim.fn.writefile(meta.stored_lines or {}, path)
	local max = math.min(#cur_lines, #meta.stored_lines)
	local branch_lnum = max + 1
	for i = 1, max do
		if cur_lines[i] ~= meta.stored_lines[i] then
			branch_lnum = i
			break
		end
	end
	local child_path = P.next_chat_path()
	vim.fn.writefile(cur_lines, child_path)
	meta.children = meta.children or {}
	table.insert(meta.children, { path = child_path, lnum = branch_lnum })
	P.write_chat_meta(path, meta)
	local child_meta = P.read_chat_meta(child_path)
	child_meta.parent = path
	child_meta.stored_lines = cur_lines
	P.write_chat_meta(child_path, child_meta)
	vim.b[buf].delphi_chat_path = child_path
	vim.b[buf].delphi_meta_path = P.chat_meta_path(child_path)
	P.render_branch_links(buf, child_meta)
	P.render_branch_graph(buf)
	return child_meta
end

---Render an overview tree of all chats connected to the current one.
---Nodes are labeled by their chat numbers and displayed at the top-right.
---@param buf integer|nil
function P.render_branch_graph(buf)
	buf = buf or 0
	local chat_path = vim.b[buf].delphi_chat_path
	if not chat_path then
		return
	end

	-- Extract the numeric chat id from a path like …/chat_42
	local function chat_id(path)
		local name = vim.fn.fnamemodify(path, ":t")
		return tonumber(name:match("chat_(%d+)") or "0") or 0
	end

	-- Find ultimate root by walking parent links
	local root = chat_path
	while true do
		local meta = P.read_chat_meta(root)
		if not meta.parent then
			break
		end
		root = meta.parent
	end

	---------------------------------------------------------------------------
	-- The tree walker – direct translation of the Python algorithm
	---------------------------------------------------------------------------
	---@param path   string
	---@param prefix string   -- leading run of "│ " or "  "
	---@param tail   boolean  -- is this the last child of its parent?
	---@param root   boolean  -- is this the real root?
	---@param lines  string[] -- accumulator
	local function walk(path, prefix, tail, is_root, lines)
		local id = chat_id(path)
		local child_pre
		if is_root then -- root has no connector
			table.insert(lines, tostring(id))
			child_pre = ""
		else
			local conn = tail and "└─" or "├─"
			table.insert(lines, prefix .. conn .. tostring(id))
			child_pre = prefix .. (tail and "  " or "│ ")
		end

		local meta = P.read_chat_meta(path)
		local children = meta.children or {}

		for i, child in ipairs(children) do
			walk(child.path, child_pre, i == #children, false, lines)
		end
	end

	-- Build the string list
	---@type string[]
	local lines = {}
	walk(root, "", false, true, lines)

	-- Compute uniform width and pad to the right
	local width = 0
	for _, l in ipairs(lines) do
		width = math.max(width, vim.fn.strdisplaywidth(l))
	end
	for i, l in ipairs(lines) do
		lines[i] = l .. string.rep(" ", width - vim.fn.strdisplaywidth(l))
	end

	---------------------------------------------------------------------------
	-- Emit as right-aligned virtual text
	---------------------------------------------------------------------------
	local line_count = vim.api.nvim_buf_line_count(buf)
	vim.api.nvim_buf_clear_namespace(buf, graph_ns, 0, -1)

	vim.api.nvim_buf_set_extmark(buf, graph_ns, 0, 0, {
		virt_text = { { "Chat tree" .. string.rep(" ", width - vim.fn.strdisplaywidth("Chat tree")), "Comment" } },
		virt_text_pos = "right_align",
		hl_mode = "combine",
	})
	for i, l in ipairs(lines) do
		local row = math.min(i - 1, line_count - 1) + 1
		vim.api.nvim_buf_set_extmark(buf, graph_ns, row, 0, {
			virt_text = { { l, "Comment" } },
			virt_text_pos = "right_align",
			hl_mode = "combine",
		})
	end
end
---Render an overview tree of all chats connected to the current one.
---Nodes are labeled by their chat numbers and displayed at the top right.
---@param buf integer|nil
function P._render_branch_graph(buf)
	buf = buf or 0
	local chat_path = vim.b[buf].delphi_chat_path
	if not chat_path then
		return
	end

	---@param path string
	---@return integer
	local function chat_id(path)
		local name = vim.fn.fnamemodify(path, ":t")
		return tonumber(name:match("chat_(%d+)") or "0") or 0
	end

	---@param path string
	---@param prefix string
	---@param lines string[]
	---@param is_first boolean
	---@param is_last boolean
	local function build_tree(path, prefix, lines, is_first, is_last)
		local id = chat_id(path)
		if prefix == "" then
			table.insert(lines, tostring(id))
		else
			local branch = is_last and "└─" or "├─"
			table.insert(lines, prefix .. branch .. tostring(id))
		end
		local meta = P.read_chat_meta(path)
		local children = meta.children or {}

		local child_prefix = prefix .. (is_first and " " or is_last and "  " or "│ ")

		for i, child in ipairs(children) do
			build_tree(child.path, child_prefix, lines, false, i == #children)
		end
	end

	local root = chat_path
	while true do
		local meta = P.read_chat_meta(root)
		if not meta.parent then
			break
		end
		root = meta.parent
	end

	---@type string[]
	local lines = {}
	build_tree(root, "", lines, true, true)
	-- print(vim.inspect(lines))

	-- Find max display width
	local max = 0
	for _, l in ipairs(lines) do
		max = math.max(max, vim.fn.strdisplaywidth(l))
	end

	-- Add virtual text with equal width
	local line_count = vim.api.nvim_buf_line_count(buf)
	for i, line in ipairs(lines) do
		local pad = max - vim.fn.strdisplaywidth(line)
		local padded = pad > 0 and (line .. string.rep(" ", pad)) or line
		print('"' .. line .. '"', pad)
		vim.api.nvim_buf_set_extmark(buf, graph_ns, math.min(i - 1, line_count - 1), 0, {
			virt_text = { { padded, "Comment" } },
			virt_text_pos = "right_align",
			hl_mode = "combine",
		})
	end

	-- vim.api.nvim_buf_clear_namespace(buf, graph_ns, 0, -1)
	-- for i, line in ipairs(lines) do
	-- 	local row = math.min(i - 1, math.max(0, line_count - 1))
	-- 	vim.api.nvim_buf_set_extmark(buf, graph_ns, row, 0, {
	-- 		virt_text = { { line, "Comment" } },
	-- 		virt_text_pos = "eol",
	-- 		hl_mode = "combine",
	-- 	})
	-- end
end

return P
