local telescope = require("telescope")
local pickers = require("telescope.pickers")
local make_entry = require("telescope.make_entry")
local finders = require("telescope.finders")
local conf = require("telescope.config").values
local previewers = require("telescope.previewers")
local actions = require("telescope.actions")
local action_state = require("telescope.actions.state")
local builtin = require("telescope.builtin")
local P = require("delphi.primitives")

local M = {}

function M.chats(opts)
	opts = opts or {}
	pickers
		.new(opts, {
			prompt_title = "Chats",
			finder = finders.new_table({
				results = P.list_chats(),
				entry_maker = function(item)
					return {
						value = item.path,
						display = item.preview,
						ordinal = item.text,
					}
				end,
			}),
			sorter = conf.generic_sorter(opts),
			previewer = previewers.new_buffer_previewer({
				define_preview = function(self, entry)
					local ok, lines = pcall(vim.fn.readfile, entry.value)
					if not ok then
						lines = { "Couldn't read file " .. tostring(entry.value) }
					end
					vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
					vim.bo[self.state.bufnr].filetype = "markdown"
				end,
			}),
			attach_mappings = function(_, map)
				map({ "i", "n" }, "<CR>", function(bufnr)
					local selection = action_state.get_selected_entry()
					actions.close(bufnr)
					P.open_chat_file(selection.value)
				end)
				return true
			end,
		})
		:find()
end

local function preview_index()
	local idx = {}
	for _, chat in ipairs(require("delphi.primitives").list_chats()) do
		idx[chat.path] = chat.preview
	end
	return idx
end

function M.grep_chats(opts)
	opts = opts or {}

	local previews = preview_index()
	local chat_paths = vim.tbl_keys(previews)

	local default_maker = make_entry.gen_from_vimgrep(opts)
	opts.entry_maker = function(raw)
		local e = default_maker(raw)
		local p = previews[e.filename] or ""
		e.display = p
		e.ordinal = p .. " " .. (e.text or "")
		return e
	end

	opts.search_dirs = chat_paths
	builtin.live_grep(opts)
end

return telescope.register_extension({
	exports = {
		chats = M.chats,
		grep_chats = M.grep_chats,
	},
})
