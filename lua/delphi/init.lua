local openai = require("delphi.openai")
local P = require("delphi.primitives")

---@class Config
---@field models table<string, Model>
---@field allow_env_var_config boolean
---@field chat { system_prompt: string, default_model: string?, headers: { system: string, user: string, assistant: string } }
---@field rewrite { system_prompt: string, default_model: string?, prompt_template: string, accept_keymap: string, reject_keymap: string, global_rewrite_keymap: string? }
local default_opts = {
	models = {},
	allow_env_var_config = false,
	chat = {
		system_prompt = "",
		default_model = nil,
		headers = {
			system = "System:",
			user = "User:",
			assistant = "Assistant:",
		},
		send_keymap = "<leader><cr>",
	},
	rewrite = {
		default_model = nil,
		system_prompt = [[
You are Delphi, an expert refactoring assistant. You ALWAYS respond with the rewritten code or text enclosed in <delphi:refactored_code> tags:
<delphi:refactored_code>
...
</delphi:refactored_code>]],
		prompt_template = [[
Full file for context:
<delphi:current_file>
{{file_text}}
</delphi:current_file>

Selected lines ({{selection_start_lnum}}:{{selection_end_lnum}}):
<delphi:selected_lines>
{{selected_text}}
</delphi:selected_lines>

Instruction: {{user_instructions}}. Return ONLY the refactored code inside <delphi:refactored_code> tags. Preserve formatting unless told otherwise. Try to keep the diff minimal while following the instructions exactly.]],
		accept_keymap = "<leader>a",
		reject_keymap = "<leader>r",
		global_rewrite_keymap = "<leader>r",
	},
}
local M = { opts = default_opts }

---Set chat send keymap
---@param chat_keymap string
---@param buf integer
function M.apply_chat_keymaps(chat_keymap, buf)
	local opts = { desc = "Send message", silent = true, buffer = buf }
	vim.keymap.set({ "n" }, chat_keymap, function()
		-- TODO: make this use a lua function
		vim.cmd([[Chat]])
	end, opts)
end

local function get_delta(chunk)
	if not chunk or not chunk.choices then
		return ""
	end
	local delta = ""
	local choice = chunk.choices[1]
	if choice then
		delta = choice.delta.content
	end
	return delta or ""
end

local function setup_chat_cmd(config)
	vim.api.nvim_create_user_command("Chat", function(opts)
		local args = opts.fargs

		if args[1] == "list" then
			for i, item in ipairs(P.list_chats()) do
				print(string.format("%d. %s", i - 1, item.preview))
			end
			return
		elseif args[1] == "go" and args[2] then
			local idx = tonumber(args[2])
			if not idx then
				return vim.notify("Invalid chat number")
			end
			local entry = P.list_chats()[idx + 1]
			if not entry then
				return vim.notify("Chat not found")
			end
			local b = P.open_chat_file(entry.path)
			M.apply_chat_keymaps(config.send_keymap, b)
			return
		end

		local orientation = nil
		if args[1] == "split" or args[1] == "sp" then
			orientation = "horizontal"
		elseif args[1] == "vsplit" or args[1] == "vsp" then
			orientation = "vertical"
		end

		local function create_chat()
			if orientation then
				P.new_split(orientation)
			end
			local default_model
			if M.opts.allow_env_var_config and os.getenv("DELPHI_DEFAULT_CHAT_MODEL") then
				default_model = os.getenv("DELPHI_DEFAULT_CHAT_MODEL")
			else
				default_model = config.default_model
			end
			local model_cfg = M.opts.models[default_model] or {}
			local b = P.open_new_chat_buffer(config.system_prompt, default_model, model_cfg.temperature)
			vim.b.is_delphi_chat = true
			vim.b.delphi_chat_path = P.next_chat_path()
			vim.b.delphi_meta_path = vim.b.delphi_chat_path:gsub("%.md$", "_meta.json")
			P.save_chat(b)
			M.apply_chat_keymaps(config.send_keymap, b)
			return b
		end

		local buf = vim.api.nvim_get_current_buf()
		if args[1] == "new" or orientation then
			create_chat()
			return
		elseif args[1] ~= nil then
			vim.notify("delphi: Invalid Chat subcommand " .. tostring(args[1]), vim.log.levels.ERROR)
			return
		end

		if not vim.b.is_delphi_chat then
			local existing = P.find_chat_buffer()
			if existing then
				P.set_current_buf(existing)
				P.set_cursor_to_user(existing)
				return
			else
				create_chat()
				return
			end
		end

		local transcript = P.read_buf(buf)
		local messages = P.to_messages(transcript)

		local meta = P.read_chat_meta(vim.b.delphi_chat_path)
		local cur_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
		local invalid = P.chat_invalidated(cur_lines, meta)
		if invalid then
			vim.notify("delphi: chat metadata file invalidated. resetting.", vim.log.levels.WARN)
			P.reset_meta(vim.b.delphi_chat_path)
			meta = P.read_chat_meta(vim.b.delphi_chat_path)
		end

		local last_role = (#messages > 0) and messages[#messages].role or ""
		if last_role ~= "user" then
			return vim.notify("The last message must be from the User!")
		end

		local new_meta, new_messages = P.resolve_tags(meta, messages)
		new_meta.chat = new_messages

		P.write_chat_meta(vim.b.delphi_chat_path, new_meta)

		P.append_line_to_buf(buf, "")
		P.append_line_to_buf(buf, P.headers.assistant)
		P.append_line_to_buf(buf, "")

		local default_model
		if M.opts.allow_env_var_config and os.getenv("DELPHI_DEFAULT_CHAT_MODEL") then
			default_model = os.getenv("DELPHI_DEFAULT_CHAT_MODEL")
		else
			default_model = config.default_model
		end
		local fm = P.parse_frontmatter(buf)
		local model_name = fm.model or default_model
		local model = M.opts.models[model_name]
		if model == nil then
			vim.notify("Coudln't find model " .. tostring(model_name), vim.log.levels.ERROR)
			return
		end
		local temperature = fm.temperature or model.temperature
		openai.chat(model, {
			stream = true,
			messages = new_messages,
			temperature = temperature,
		}, {
			on_chunk = function(chunk, is_done)
				if is_done then
					P.append_line_to_buf(buf, "")
					P.append_line_to_buf(buf, P.headers.user .. " ")
					P.append_line_to_buf(buf, "")
					P.set_cursor_to_user(buf)
					P.save_chat(buf)
					return
				end
				P.append_chunk_to_buf(buf, get_delta(chunk))
			end,

			on_error = vim.notify,
		})
	end, { nargs = "*" })
end

local function setup_rewrite_cmd(config)
	vim.api.nvim_create_user_command("Rewrite", function()
		local orig_buf = vim.api.nvim_get_current_buf()
		local sel = P.get_visual_selection(orig_buf)
		if #sel.lines == 0 then
			return vim.notify("No visual selection found.", vim.log.levels.WARN)
		end
		local file_lines = vim.api.nvim_buf_get_lines(orig_buf, 0, -1, false)

		P.show_popup("Rewrite prompt", function(user_prompt)
			vim.notify(user_prompt)
			if user_prompt == "" then
				vim.notify("Empty prompt")
				return
			end -- cancelled

			local env = {
				file_text = table.concat(file_lines, "\n"),
				selected_text = table.concat(sel.lines, "\n"),
				selection_start_lnum = sel.start_lnum,
				selection_end_lnum = sel.end_lnum,
				user_instructions = user_prompt,
			}

			-- simple fence-aware streaming state
			local Extractor = require("delphi.extractor").Extractor
			local extractor = Extractor.new()

			local diff = P.start_ghost_diff(orig_buf, sel.start_lnum, sel.end_lnum, sel.lines)
			local default_model
			if M.opts.allow_env_var_config and os.getenv("DELPHI_DEFAULT_REWRITE_MODEL") then
				default_model = os.getenv("DELPHI_DEFAULT_REWRITE_MODEL")
			else
				default_model = config.default_model
			end
			local model = M.opts.models[default_model]
			if not model then
				vim.notify("Coudln't find model " .. tostring(default_model), vim.log.levels.ERROR)
				return
			end

			openai.chat(model, {
				stream = true,
				messages = {
					{ role = "system", content = M.opts.rewrite.system_prompt },
					{ role = "user", content = P.template(M.opts.rewrite.prompt_template, env) },
				},
			}, {
				on_chunk = function(chunk, is_done)
					if is_done then
						local map = vim.keymap.set
						map("n", config.accept_keymap, function()
							diff.accept()
							vim.notify("applied")
						end, { buffer = orig_buf })
						map("n", config.reject_keymap, function()
							diff.reject()
							vim.notify("rejected")
						end, { buffer = orig_buf })
						vim.notify(
							"Rewrite finished – "
								.. config.accept_keymap
								.. " accept "
								.. config.reject_keymap
								.. " reject",
							vim.log.levels.INFO
						)
						return
					end
					local new_code = extractor:update(get_delta(chunk))
					if #new_code then
						diff.push(new_code)
					end
				end,

				on_error = function() end,
			})
		end)
	end, { range = true, desc = "LLM-rewrite the current visual selection" })
end

---Setup delphi
---@param opts Config
function M.setup(opts)
	local models = opts.models or {}
	local Model = require("delphi.model").Model
	for k, v in pairs(models) do
		models[k] = Model.new(v)
	end

	M.opts = vim.tbl_deep_extend("force", M.opts, opts or {})

	P.set_headers(M.opts.chat.headers)
	setup_chat_cmd(M.opts.chat)
	setup_rewrite_cmd(M.opts.rewrite)

	local ok, cmp = pcall(require, "cmp")
	if ok then
		cmp.register_source("delphi_path", require("delphi.cmp_source"))
	end
	local global_rewrite_keymap = M.opts.rewrite.global_rewrite_keymap
	if global_rewrite_keymap then
		vim.keymap.set("x", global_rewrite_keymap, ":Rewrite<cr>", { noremap = true, silent = true })
	end
end

return M
