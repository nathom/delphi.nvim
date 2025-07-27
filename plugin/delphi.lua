local openai = require("delphi.openai")
local P = require("delphi.primitives")
local M = { opts = { fold = true, system_prompt = nil } }

function M.setup(opts)
	M.opts = vim.tbl_deep_extend("force", M.opts, opts or {})
end

vim.api.nvim_create_user_command("Chat", function(opts)
	local buf = vim.api.nvim_get_current_buf()
	if not vim.b.is_delphi_chat then -- flag optional
		buf = P.open_new_chat_buffer(opts.args) -- opts.args → system prompt
		vim.b.is_delphi_chat = true
		return -- first call just opens buffer
	end

	local transcript = P.read_buf(buf)
	local messages = P.to_messages(transcript)
	local last_role = (#messages > 0) and messages[#messages].role or ""
	if last_role ~= "user" then -- nothing new to send
		return vim.notify("The last message must be from the User!")
	end

	P.append_line_to_buf(buf, "") -- spacer
	P.append_line_to_buf(buf, "Assistant:")
	P.append_line_to_buf(buf, "") -- where streaming will go

	openai.setup({ api_key = os.getenv("OPENAI_API_KEY") })
	openai.chat({
		model = "gpt-4o", -- or gemini-flash-lite
		stream = true,
		messages = messages,
	}, {
		on_chunk = vim.schedule_wrap(function(chunk)
			local delta = chunk.choices[1].delta.content or ""
			P.append_chunk_to_buf(buf, delta) -- newline safe
		end),

		on_done = function()
			-- ready for next turn
			P.append_line_to_buf(buf, "")
			P.append_line_to_buf(buf, "User: ")
			P.append_line_to_buf(buf, "")
			P.set_cursor_to_user(buf)
		end,

		on_error = vim.notify,
	})
end, { nargs = "?" }) -- optional s

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
		local system_msg = "You are an expert refactoring assistant. "
			.. "Return ONLY the rewritten code wrapped in one fenced block: ```\n…\n```."

		local user_msg = table.concat({
			"Full file for context:",
			"```",
			table.concat(file_lines, "\n"),
			"```",
			"",
			("Selected lines (%d–%d):"):format(sel.start_lnum, sel.end_lnum),
			"```",
			table.concat(sel.lines, "\n"),
			"```",
			"",
			"Instruction:",
			user_prompt,
		}, "\n")

		-- simple fence-aware streaming state
		local Extractor = require("delphi.extractor").Extractor
		local extractor = Extractor.new()

		local diff = P.start_inline_diff(orig_buf, sel.start_lnum, sel.end_lnum, sel.lines)
		openai.chat({
			model = "gpt-4o",
			stream = true,
			messages = {
				{ role = "system", content = system_msg },
				{ role = "user", content = user_msg },
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
				map("n", "<space>a", function()
					diff.accept()
					vim.notify("applied")
				end, { buffer = orig_buf })
				map("n", "<space>r", function()
					diff.reject()
					vim.notify("rejected")
				end, { buffer = orig_buf })
				vim.notify("Refactor finished – ‹a› accept  ‹r› reject", vim.log.levels.INFO)
			end,
			on_error = vim.notify,
		})
	end)
end, { range = true, desc = "LLM-rewrite the current visual selection" })

return M
