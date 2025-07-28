local openai = require("delphi.openai")
local P = require("delphi.primitives")

local default_opts = {
	chat = {
		system_prompt = "",
	},
	refactor = {
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

Instruction: {{user_instructions}}]],
		accept_keymap = "<leader>a",
		reject_keymap = "<leader>r",
	},
}
local M = { opts = default_opts }

local function setup_chat_cmd(config)
	vim.api.nvim_create_user_command("Chat", function()
		local buf = vim.api.nvim_get_current_buf()
		if not vim.b.is_delphi_chat then
			buf = P.open_new_chat_buffer(config.system_prompt)
			vim.b.is_delphi_chat = true
			return
		end

		local transcript = P.read_buf(buf)
		local messages = P.to_messages(transcript)
		local last_role = (#messages > 0) and messages[#messages].role or ""
		if last_role ~= "user" then -- nothing new to send
			return vim.notify("The last message must be from the User!")
		end

		P.append_line_to_buf(buf, "")
		P.append_line_to_buf(buf, "Assistant:")
		P.append_line_to_buf(buf, "")

		openai.setup({ api_key = os.getenv("OPENAI_API_KEY") })
		openai.chat({
			model = "gpt-4o",
			stream = true,
			messages = messages,
		}, {
			on_chunk = vim.schedule_wrap(function(chunk)
				local delta = chunk.choices[1].delta.content or ""
				P.append_chunk_to_buf(buf, delta)
			end),

			on_done = function()
				P.append_line_to_buf(buf, "")
				P.append_line_to_buf(buf, "User: ")
				P.append_line_to_buf(buf, "")
				P.set_cursor_to_user(buf)
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

			openai.setup({ api_key = os.getenv("OPENAI_API_KEY") })

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
			openai.chat({
				model = "gpt-4o",
				stream = true,
				messages = {
					{ role = "system", content = M.opts.refactor.system_prompt },
					{ role = "user", content = P.template(M.opts.refactor.prompt_template, env) },
				},
			}, {
				on_chunk = vim.schedule_wrap(function(chunk)
					local delta = chunk.choices[1].delta.content or ""
					local new_code = extractor:update(delta)
					if #new_code then
						diff.push(new_code)
					end
				end),

				on_done = function()
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
				end,
				on_error = vim.notify,
			})
		end)
	end, { range = true, desc = "LLM-rewrite the current visual selection" })
end

function M.setup(opts)
	M.opts = vim.tbl_deep_extend("force", M.opts, opts or {})
	setup_chat_cmd(M.opts.chat)
	setup_refactor_cmd(M.opts.refactor)
end

return M
