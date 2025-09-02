-- Note: avoid heavy requires at module load time.
-- We require modules like openai/primitives only inside the functions
-- that actually use them to keep startup overhead minimal.

---@class Config
---@field models table<string, Model>
---@field allow_env_var_config boolean
---@field chat { system_prompt: string, default_model: string?, headers: { system: string, user: string, assistant: string }, scroll_on_send: boolean }
---@field rewrite { default_model: string? }
---@field max_prompt_window_width integer|nil
local default_opts = {
	models = {},
	allow_env_var_config = false,
	max_prompt_window_width = nil,
	chat = {
		system_prompt = "",
		default_model = nil,
		headers = {
			system = "System:",
			user = "User:",
			assistant = "Assistant:",
		},
		scroll_on_send = true,
	},
	rewrite = {
		default_model = nil,
		accept_keymap = "<leader>a",
		reject_keymap = "<leader>r",
		global_rewrite_keymap = "<leader>r",
	},
}
local M = { opts = default_opts }

---Set chat send keymap
---@param buf integer
function M.apply_chat_keymaps(buf)
	-- Delegate to primitives to keep all API usage centralized and idempotent.
	-- This now applies a global <Plug> mapping so user keymaps work regardless
	-- of how the chat buffer was opened (Telescope, Chat go, etc.).
	local P = require("delphi.primitives")
	P.apply_chat_plug_mappings()
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
		local P = require("delphi.primitives")
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
			M.apply_chat_keymaps(b)
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
			M.apply_chat_keymaps(b)
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
				M.apply_chat_keymaps(existing)
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
		new_meta.stored_lines = cur_lines

		P.write_chat_meta(vim.b.delphi_chat_path, new_meta)

		-- Optionally scroll so the last User header is at the top
		if config.scroll_on_send then
			P.scroll_last_user_to_top(buf)
		end

		-- Add assistant header and start a right-aligned spinner on that line
		P.append_line_to_buf(buf, "")
		P.append_line_to_buf(buf, P.headers.assistant)
		local assistant_header_lnum = vim.api.nvim_buf_line_count(buf) -- 1-based
		P.append_line_to_buf(buf, "")

		local assistant_spinner = require("delphi.spinner").new({
			bufnr = buf,
			autohide_on_stop = true,
			row = assistant_header_lnum - 1, -- extmark rows are 0-based
			label = "Generating",
			virt_text_pos = "right_align",
		})
		assistant_spinner:start()

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
		local openai = require("delphi.openai")
		openai.chat(model, {
			stream = true,
			messages = new_messages,
			temperature = temperature,
		}, {
			on_chunk = function(chunk, is_done)
				if is_done then
					if assistant_spinner then
						assistant_spinner:stop()
					end
					P.append_line_to_buf(buf, "")
					P.append_line_to_buf(buf, P.headers.user .. " ")
					P.append_line_to_buf(buf, "")
					P.set_cursor_to_user(buf)
					P.save_chat(buf)
					return
				end
				P.append_chunk_to_buf(buf, get_delta(chunk))
			end,

			on_error = function(err)
				if assistant_spinner then
					assistant_spinner:stop()
				end
				vim.notify(err)
			end,
		})
	end, { nargs = "*" })
	-- Ensure global <Plug> mapping exists so user mappings always work.
	require("delphi.primitives").apply_chat_plug_mappings()
end

local function setup_rewrite_cmd(config)
	vim.api.nvim_create_user_command("Rewrite", function()
		local P = require("delphi.primitives")
		local orig_buf = vim.api.nvim_get_current_buf()
		local sel = P.get_visual_selection(orig_buf)
		if #sel.lines == 0 then
			return vim.notify("No visual selection found.", vim.log.levels.WARN)
		end

		P.show_popup("Rewrite prompt", function(user_prompt)
			if user_prompt == "" then
				vim.notify("Empty prompt")
				return
			end -- cancelled

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
			local think_spinner = require("delphi.spinner").new({
				bufnr = vim.api.nvim_get_current_buf(),
				autohide_on_stop = true,
				-- spinner row is 0-based; anchor to the top line of the region
				row = sel.start_lnum - 1,
				label = "Generating",
				virt_text_pos = "right_align",
			})
			think_spinner:start()
			local rewrite_prompt = P.build_rewrite_prompt(orig_buf, sel.start_lnum, sel.end_lnum, user_prompt)

			local openai = require("delphi.openai")
			openai.chat(model, {
				stream = true,
				messages = {
					{ role = "user", content = rewrite_prompt },
				},
			}, {
				on_chunk = function(chunk, is_done)
					if is_done then
						local map = vim.keymap.set
						map("n", "<Plug>(DelphiRewriteAccept)", function()
							diff.accept()
							P.echo("")
						end, { buffer = orig_buf, desc = "Delphi: accept rewrite", silent = true })
						map("n", "<Plug>(DelphiRewriteReject)", function()
							diff.reject()
							P.echo("")
						end, { buffer = orig_buf, desc = "Delphi: reject rewrite", silent = true })
						think_spinner:stop()

						-- Show concise key hints that reflect actual mappings
						local accept_hint = P.mapping_hint_for_plug(
							"<Plug>(DelphiRewriteAccept)",
							orig_buf,
							M.opts.rewrite and M.opts.rewrite.accept_keymap
						)
						local reject_hint = P.mapping_hint_for_plug(
							"<Plug>(DelphiRewriteReject)",
							orig_buf,
							M.opts.rewrite and M.opts.rewrite.reject_keymap
						)
						P.echo(string.format("%s to accept, %s to reject", accept_hint, reject_hint))
					end
					local new_code = extractor:update(get_delta(chunk))
					if #new_code then
						diff.push(new_code)
					end
				end,

				on_error = function() end,
			})
		end)
	end, { range = true, desc = "LLM-rewrite the current visual selection or insert-at-cursor" })
	-- Define <Plug> mappings once so users can bind ergonomically
	require("delphi.primitives").apply_rewrite_plug_mappings()
end

local function setup_explain_cmd()
	vim.api.nvim_create_user_command("Explain", function()
		local P = require("delphi.primitives")
		local orig_buf = vim.api.nvim_get_current_buf()
		local sel = P.get_visual_selection(orig_buf)
		if #sel.lines == 0 then
			return vim.notify("No visual selection found.", vim.log.levels.WARN)
		end

		P.show_popup("Explain prompt", function(user_prompt)
			if user_prompt == "" then
				vim.notify("Empty prompt")
				return
			end -- cancelled

			-- Build the prompt with @-tagged file
			local path = P.current_file_path(orig_buf)
			local ft = vim.bo[orig_buf].filetype
			local snippet = table.concat(sel.lines, "\n")
			local user_msg = require("delphi.explain").build_prompt({
				file_path = (path ~= "" and path or nil),
				snippet = snippet,
				language_name = ft,
				user_prompt = user_prompt,
			})

			-- Create a new chat buffer, prefill content, and send
			local system_prompt = M.opts.chat.system_prompt
			local default_model
			if M.opts.allow_env_var_config and os.getenv("DELPHI_DEFAULT_EXPLAIN_MODEL") then
				default_model = os.getenv("DELPHI_DEFAULT_EXPLAIN_MODEL")
			elseif M.opts.allow_env_var_config and os.getenv("DELPHI_DEFAULT_CHAT_MODEL") then
				default_model = os.getenv("DELPHI_DEFAULT_CHAT_MODEL")
			else
				default_model = M.opts.chat.default_model
			end
			local model_cfg = M.opts.models[default_model] or {}

			local b = P.open_new_chat_buffer(system_prompt, default_model, model_cfg.temperature)
			vim.b.is_delphi_chat = true
			vim.b.delphi_chat_path = P.next_chat_path()
			vim.b.delphi_meta_path = vim.b.delphi_chat_path:gsub("%.md$", "_meta.json")
			P.set_last_user_content(b, user_msg)
			P.save_chat(b)

			M.apply_chat_keymaps(b)

			-- Kick off the chat streaming for this buffer
			vim.cmd([[Chat]])
		end)
	end, { range = true, desc = "Explain the current visual selection via LLM" })

	-- Define <Plug> mappings once for ergonomic usage
	require("delphi.primitives").apply_explain_plug_mappings()
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

	-- Configure primitives with headers (safe/lightweight)
	local P = require("delphi.primitives")
	P.set_headers(M.opts.chat.headers)
	P.set_prompt_max_width(M.opts.max_prompt_window_width)
	setup_chat_cmd(M.opts.chat)
	setup_rewrite_cmd(M.opts.rewrite)
	setup_explain_cmd()
end

return M
