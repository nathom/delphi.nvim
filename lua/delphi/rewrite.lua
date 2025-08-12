--- Build a formatted prompt equivalent to the given Handlebars template.
--- @param p {language_name:string|nil, is_insert:boolean, document_content:string, is_truncated:boolean, content_type:string, user_prompt:string, rewrite_section:string|nil} p Arguments table
--- @return string The formatted prompt
local function build_prompt(p)
	local out = {}
	-- Header line
	if p.language_name and p.language_name ~= "" then
		table.insert(out, "Here's a file of " .. p.language_name .. " that I'm going to ask you to make an edit to.")
	else
		table.insert(out, "Here's a file of text that I'm going to ask you to make an edit to.")
	end

	-- Insert vs rewrite explainer
	if p.is_insert then
		table.insert(out, "The point you'll need to insert at is marked with <insert_here></insert_here>.")
	else
		table.insert(out, "The section you'll need to rewrite is marked with <rewrite_this></rewrite_this> tags.")
	end

	-- Document block
	table.insert(out, "")
	table.insert(out, "<document>")
	table.insert(out, p.document_content or "")
	table.insert(out, "</document>")
	table.insert(out, "")

	-- Truncation note
	if p.is_truncated then
		table.insert(
			out,
			"The context around the relevant section has been truncated (possibly in the middle of a line) for brevity."
		)
		table.insert(out, "")
	end

	if p.is_insert then
		-- Insert branch instructions
		table.insert(
			out,
			("You can't replace %s, your answer will be inserted in place of the `<insert_here></insert_here>` tags. Don't include the insert_here tags in your output."):format(
				p.content_type
			)
		)
		table.insert(out, "")
		table.insert(out, ("Generate %s based on the following prompt:"):format(p.content_type))
		table.insert(out, "")
		table.insert(out, "<prompt>")
		table.insert(out, p.user_prompt or "")
		table.insert(out, "</prompt>")
		table.insert(out, "")
		table.insert(
			out,
			("Match the indentation in the original file in the inserted %s, don't include any indentation on blank lines."):format(
				p.content_type
			)
		)
		table.insert(out, "")
		table.insert(out, "Immediately start with the following format with no remarks:")
		table.insert(out, "")
		table.insert(out, "```")
		table.insert(out, "\\{{INSERTED_CODE}}")
		table.insert(out, "```")
	else
		-- Rewrite branch instructions
		table.insert(
			out,
			("Edit the section of %s in <rewrite_this></rewrite_this> tags based on the following prompt:"):format(
				p.content_type
			)
		)
		table.insert(out, "")
		table.insert(out, "<prompt>")
		table.insert(out, p.user_prompt or "")
		table.insert(out, "</prompt>")
		table.insert(out, "")

		if p.rewrite_section and p.rewrite_section ~= "" then
			table.insert(out, "And here's the section to rewrite based on that prompt again for reference:")
			table.insert(out, "")
			table.insert(out, "<rewrite_this>")
			table.insert(out, p.rewrite_section)
			table.insert(out, "</rewrite_this>")
			table.insert(out, "")
		end

		table.insert(
			out,
			("Only make changes that are necessary to fulfill the prompt, leave everything else as-is. All surrounding %s will be preserved."):format(
				p.content_type
			)
		)
		table.insert(out, "")
		table.insert(
			out,
			("Start at the indentation level in the original file in the rewritten %s. Don't stop until you've rewritten the entire section, even if you have no more changes to make, always write out the whole section with no unnecessary elisions."):format(
				p.content_type
			)
		)
		table.insert(out, "")
		table.insert(out, "Immediately start with the following format with no remarks:")
		table.insert(out, "")
		table.insert(out, "```")
		table.insert(out, "\\{{REWRITTEN_CODE}}")
		table.insert(out, "```")
	end

	return table.concat(out, "\n")
end

return { build_prompt = build_prompt }
