local openai = require("delphi.openai")
local P = require("delphi.primitives")

---@class Config
---@field models table<string, Model>
---@field allow_env_var_config boolean
---@field chat { system_prompt: string, default_model: string? }
---@field refactor { system_prompt: string, default_model: string?, prompt_template: string, accept_keymap: string, reject_keymap: string }
local default_opts = {
	models = {},
	allow_env_var_config = false,
       chat = {
               system_prompt = "",
               default_model = nil,
               enable_cmp = false,
       },
	refactor = {
		default_model = nil,
		system_prompt = [[
You are an expert refactoring assistant. Return ONLY the rewritten code in one fenced block:
```
...
```.]],
		prompt_template = [[
Full file for context:
```
{{file_text}}
```

Selected lines ({{selection_start_lnum}}:{{selection_end_lnum}}):
```
{{selected_text}}
```

Instruction: {{user_instructions}}. Return ONLY the refactored code within a code block. Preserve formatting unless told otherwise. Try to keep the diff minimal while following the instructions exactly.]],
		accept_keymap = "<leader>a",
		reject_keymap = "<leader>r",
	},
}
local M = { opts = default_opts }

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
	vim.api.nvim_create_user_command("Chat", function()
               local buf = vim.api.nvim_get_current_buf()
               if not vim.b.is_delphi_chat then
                       buf = P.open_new_chat_buffer(config.system_prompt, { enable_cmp = config.enable_cmp })
                       vim.b.is_delphi_chat = true
                       return
               end

               local transcript = P.read_buf(buf)
               local messages = P.to_messages(transcript)
               for _, m in ipairs(messages) do
                       m.content = P.expand_file_tags(m.content)
               end
		local last_role = (#messages > 0) and messages[#messages].role or ""
		if last_role ~= "user" then -- nothing new to send
			return vim.notify("The last message must be from the User!")
		end

		P.append_line_to_buf(buf, "")
		P.append_line_to_buf(buf, "Assistant:")
		P.append_line_to_buf(buf, "")

		local default_model
		if M.opts.allow_env_var_config and os.getenv("DELPHI_DEFAULT_CHAT_MODEL") then
			default_model = os.getenv("DELPHI_DEFAULT_CHAT_MODEL")
		else
			default_model = config.default_model
		end
		local model = M.opts.models[default_model]
		if model == nil then
			vim.notify("Coudln't find model " .. tostring(default_model), vim.log.levels.ERROR)
			return
		end
		openai.chat(model, {
			stream = true,
			messages = messages,
		}, {
			on_chunk = vim.schedule_wrap(function(chunk, is_done)
				if is_done then
					P.append_line_to_buf(buf, "")
					P.append_line_to_buf(buf, "User: ")
					P.append_line_to_buf(buf, "")
					P.set_cursor_to_user(buf)
					return
				end
				P.append_chunk_to_buf(buf, get_delta(chunk))
			end),

			on_done = function()
				-- vim.notify(debug.traceback("msg", 5))
				-- P.append_line_to_buf(buf, "")
				-- P.append_line_to_buf(buf, "User: ")
				-- P.append_line_to_buf(buf, "")
				-- P.set_cursor_to_user(buf)
			end,

			on_error = vim.notify,
		})
	end, { nargs = "?" })
end

local function setup_refactor_cmd(config)
	vim.api.nvim_create_user_command("Refactor", function()
		local orig_buf = vim.api.nvim_get_current_buf()
		local sel = P.get_visual_selection(orig_buf)
		if #sel.lines == 0 then
			return vim.notify("No visual selection found.", vim.log.levels.WARN)
		end
		local file_lines = vim.api.nvim_buf_get_lines(orig_buf, 0, -1, false)

		P.show_popup("Refactor prompt", function(user_prompt)
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

			local diff = P.start_inline_diff(orig_buf, sel.start_lnum, sel.end_lnum, sel.lines)
			local default_model
			if M.opts.allow_env_var_config and os.getenv("DELPHI_DEFAULT_REFACTOR_MODEL") then
				default_model = os.getenv("DELPHI_DEFAULT_REFACTOR_MODEL")
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
					{ role = "system", content = M.opts.refactor.system_prompt },
					{ role = "user", content = P.template(M.opts.refactor.prompt_template, env) },
				},
			}, {
				on_chunk = vim.schedule_wrap(function(chunk, is_done)
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
							"Refactor finished – "
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
				end),

				on_done = function() end,
				on_error = function(err_output)
					print("called on error")
				end,
			})
		end)
	end, { range = true, desc = "LLM-rewrite the current visual selection" })
end

---Setup delphi
---@param opts Config
function M.setup(opts)
	local models = opts.models
	local Model = require("delphi.model").Model
	for k, v in pairs(models) do
		models[k] = Model.new(v)
	end
	M.opts = vim.tbl_deep_extend("force", M.opts, opts or {})
	setup_chat_cmd(M.opts.chat)
	setup_refactor_cmd(M.opts.refactor)
end

return M
