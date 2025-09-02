local M = {}

---Build a user message asking to explain a snippet.
---@param p { file_path: string|nil, snippet: string, language_name: string|nil, user_prompt: string|nil }
---@return string
function M.build_prompt(p)
	local out = {}

	local lang = (p.language_name and p.language_name ~= "") and (" %s"):format(p.language_name) or ""
	local has_file = p.file_path and p.file_path ~= ""

	-- Derive a reasonable code fence language
	local ext = ""
	if type(p.file_path) == "string" and p.file_path ~= "" then
		ext = p.file_path:match("%.([%w_]+)$") or ""
	end
	if (not ext or ext == "") and type(p.language_name) == "string" and p.language_name ~= "" then
		ext = p.language_name
	end

	local has_user_prompt = p.user_prompt and p.user_prompt ~= ""

	if has_user_prompt then
		if has_file then
			table.insert(out, ("Consider the following%s code snippet from @%s "):format(lang, p.file_path))
		else
			table.insert(out, ("Consider the following%s code snippet:"):format(lang))
		end
	else
		if has_file then
			table.insert(out, ("Explain the following%s code snippet taken from @%s "):format(lang, p.file_path))
		else
			table.insert(out, ("Explain the following%s code snippet:"):format(lang))
		end
	end
	table.insert(out, "")

	if has_user_prompt then
		table.insert(out, "<delphi:user_prompt>")
		table.insert(out, p.user_prompt)
		table.insert(out, "</delphi:user_prompt>")
		table.insert(out, "")
	end

	table.insert(out, "<delphi:selected_snippet>")
	table.insert(out, string.format("```%s", ext or ""))
	table.insert(out, p.snippet or "")
	table.insert(out, "```")
	table.insert(out, "</delphi:selected_snippet>")
	table.insert(out, "")

	if has_file then
		table.insert(out, "You may reference surrounding context from the tagged file above if needed.")
	end
	if not has_user_prompt then
		table.insert(out, "Focus on what it does, important behaviors, and any edge cases.")
	end

	return table.concat(out, "\n")
end

return M
