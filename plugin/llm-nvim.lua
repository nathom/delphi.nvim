-- plugin/myllm.lua -----------------------------------------------------------
-- Streaming chat with turn-level folding + full multi-turn context.
-- Setup:
--   require('myllm').setup{ fold=true, system_prompt='You are terse.' }
-- Commands:
--   :Chat   – open / continue chat (maintains full history)
--   :LLM    – quick one-shot demo

local openai = require("llm-nvim.openai")
local P = require("llm-nvim.primitives")
local M = { opts = { fold = true, system_prompt = nil } }

function M.setup(opts)
	M.opts = vim.tbl_deep_extend("force", M.opts, opts or {})
end

vim.api.nvim_create_user_command("Chat", function(opts)
	------------------------------------------------------------
	-- 1. Ensure we’re in a chat buffer, or create one
	------------------------------------------------------------
	local buf = vim.api.nvim_get_current_buf()
	if not vim.b.is_myllm_chat then -- flag optional
		buf = P.open_new_chat_buffer(opts.args) -- opts.args → system prompt
		vim.b.is_myllm_chat = true
		return -- first call just opens buffer
	end

	------------------------------------------------------------
	-- 2. Grab full conversation and the latest user prompt
	------------------------------------------------------------
	local transcript = P.read_buf(buf)
	local messages = P.to_messages(transcript)
	local last_role = (#messages > 0) and messages[#messages].role or ""
	if last_role ~= "user" then -- nothing new to send
		return vim.notify("The last message must be from the User!")
	end
	--
	-- ------------------------------------------------------------
	-- -- 3. Append Assistant header + blank line
	-- ------------------------------------------------------------
	P.append_line_to_buf(buf, "") -- spacer
	P.append_line_to_buf(buf, "Assistant:")
	P.append_line_to_buf(buf, "") -- where streaming will go
	--
	-- ------------------------------------------------------------
	-- -- 4. Call OpenAI; stream tokens into the last line
	-- ------------------------------------------------------------
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

local function after_fence(s)
	local _, finish = s:find("```")
	if finish then
		return s:sub(finish + 1)
	else
		return ""
	end
end
local function before_fence(s)
	local start_pos = s:find("```")
	if start_pos then
		if start_pos > 1 then
			return s:sub(1, start_pos - 1)
		else
			return ""
		end
	else
		return s
	end
end
-------------------------------------------------------------------------------
-- :Refactor  –  LLM-powered in-place rewrite of a visual selection
-------------------------------------------------------------------------------
vim.api.nvim_create_user_command("Refactor", function()
	---------------------------------------------------------------------------
	-- 1 · gather context (buffer + visual selection)
	---------------------------------------------------------------------------
	local orig_buf = vim.api.nvim_get_current_buf()
	local sel = P.get_visual_selection(orig_buf)
	if #sel.lines == 0 then
		return vim.notify("No visual selection found.", vim.log.levels.WARN)
	end
	local file_lines = vim.api.nvim_buf_get_lines(orig_buf, 0, -1, false)

	---------------------------------------------------------------------------
	-- 2 · ask user for the rewrite instruction
	---------------------------------------------------------------------------
	P.show_popup("Refactor prompt", function(user_prompt)
		vim.notify(user_prompt)
		if user_prompt == "" then
			vim.notify("Empty prompt")
			return
		end -- cancelled

		-----------------------------------------------------------------------
		-- 4 · call LLM
		-----------------------------------------------------------------------
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
		local diff = P.start_inline_diff(orig_buf, sel.start_lnum, sel.end_lnum, sel.lines)
		local in_code = false

		local full_response = ""
		local response = ""
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
				full_response = full_response .. delta
				if not in_code then
					local fence_idx = full_response:find("```", 1, true)
					if fence_idx then
						response = after_fence(full_response)
						diff.push(response)
						in_code = true
					end
				else
					response = response .. before_fence(delta)
					diff.push(before_fence(delta))
				end
			end),

			on_done = function()
				vim.notify(response)
				vim.notify(full_response)
				local map = vim.keymap.set
				map("n", "<leader>a", function()
					diff.accept()
					vim.notify("applied")
				end, { buffer = orig_buf })
				map("n", "<leader>r", function()
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
