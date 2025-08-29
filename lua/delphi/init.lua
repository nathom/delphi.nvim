-- Note: avoid heavy requires at module load time.
-- We require modules like openai/primitives only inside the functions
-- that actually use them to keep startup overhead minimal.

---@class Config
---@field models table<string, Model>
---@field allow_env_var_config boolean
---@field chat { system_prompt: string, default_model: string?, headers: { system: string, user: string, assistant: string } }
---@field rewrite { default_model: string? }
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
	},
	rewrite = {
		default_model = nil,
		accept_keymap = "<leader>a",
		reject_keymap = "<leader>r",
		global_rewrite_keymap = "<leader>r",
	},
}
local M = { opts = default_opts }

-- All editor keymaps should be defined via primitives.

local get_delta = require("delphi.util").get_stream_delta

local function setup_chat_cmd(config)
	local P = require("delphi.primitives")
	P.create_user_command("Chat", function(opts)
		local args = opts.fargs

		if args[1] == "list" then
			for i, item in ipairs(P.list_chats()) do
				print(string.format("%d. %s", i - 1, item.preview))
			end
			return
		elseif args[1] == "go" and args[2] then
			local idx = tonumber(args[2])
            if not idx then
                return P.notify("Invalid chat number")
            end
			local entry = P.list_chats()[idx + 1]
            if not entry then
                return P.notify("Chat not found")
            end
			local b = P.open_chat_file(entry.path)
			P.apply_chat_keymaps(b)
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
			local chat_path = P.next_chat_path()
			P.set_bvar(b, "is_delphi_chat", true)
			P.set_bvar(b, "delphi_chat_path", chat_path)
			P.set_bvar(b, "delphi_meta_path", chat_path:gsub("%.md$", "_meta.json"))
			P.save_chat(b)
			P.apply_chat_keymaps(b)
			return b
		end

		local buf = P.get_current_buf()
		if args[1] == "new" or orientation then
			create_chat()
			return
		elseif args[1] ~= nil then
			P.notify("delphi: Invalid Chat subcommand " .. tostring(args[1]), vim.log.levels.ERROR)
			return
		end

		if not vim.b.is_delphi_chat then
			local existing = P.find_chat_buffer()
			if existing then
				P.set_current_buf(existing)
				P.set_cursor_to_user(existing)
				P.apply_chat_keymaps(existing)
				return
			else
				create_chat()
				return
			end
		end

		local transcript = P.read_buf(buf)
		local messages = P.to_messages(transcript)

		local chat_path = P.get_bvar(nil, "delphi_chat_path", "")
		local meta = P.read_chat_meta(chat_path)
		local cur_lines = P.buf_get_lines(buf, 0, -1)
		local invalid = P.chat_invalidated(cur_lines, meta)
		if invalid then
			P.notify("delphi: chat metadata file invalidated. resetting.", vim.log.levels.WARN)
			P.reset_meta(chat_path)
			meta = P.read_chat_meta(chat_path)
		end

		local last_role = (#messages > 0) and messages[#messages].role or ""
		if last_role ~= "user" then
			return P.notify("The last message must be from the User!")
		end

		local new_meta, new_messages = P.resolve_tags(meta, messages)
		new_meta.stored_lines = cur_lines

		P.write_chat_meta(chat_path, new_meta)

		-- Add assistant header and start a right-aligned spinner on that line
		P.append_line_to_buf(buf, "")
		P.append_line_to_buf(buf, P.headers.assistant)
		local assistant_header_lnum = P.buf_line_count(buf) -- 1-based
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
			P.notify("Coudln't find model " .. tostring(model_name), vim.log.levels.ERROR)
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
				P.notify(err)
			end,
		})
	end, { nargs = "*" })
end

local function setup_rewrite_cmd(config)
	local P = require("delphi.primitives")
	P.create_user_command("Rewrite", function()
		local orig_buf = P.get_current_buf()
		local sel = P.get_visual_selection(orig_buf)
		if #sel.lines == 0 then
			return P.notify("No visual selection found.", vim.log.levels.WARN)
		end

		P.show_popup("Rewrite prompt", function(user_prompt)
			if user_prompt == "" then
				P.notify("Empty prompt")
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
				P.notify("Coudln't find model " .. tostring(default_model), vim.log.levels.ERROR)
				return
			end
			local think_spinner = require("delphi.spinner").new({
				bufnr = P.get_current_buf(),
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
						P.keymap_set("n", "<Plug>(DelphiRewriteAccept)", function()
							diff.accept()
							P.notify("applied")
						end, { buffer = orig_buf, desc = "Delphi: accept rewrite", silent = true })
						P.keymap_set("n", "<Plug>(DelphiRewriteReject)", function()
							diff.reject()
							P.notify("rejected")
						end, { buffer = orig_buf, desc = "Delphi: reject rewrite", silent = true })
						think_spinner:stop()
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
	setup_chat_cmd(M.opts.chat)
	setup_rewrite_cmd(M.opts.rewrite)
end

return M
