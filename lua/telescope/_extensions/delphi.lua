local pickers = require('telescope.pickers')
local finders = require('telescope.finders')
local conf = require('telescope.config').values
local previewers = require('telescope.previewers')
local actions = require('telescope.actions')
local action_state = require('telescope.actions.state')
local P = require('delphi.primitives')
local telescope = require('telescope')

local M = {}

function M.chats(opts)
  opts = opts or {}
  pickers.new(opts, {
    prompt_title = 'Chats',
    finder = finders.new_table({
      results = P.list_chats(),
      entry_maker = function(item)
        return {
          value = item.path,
          display = item.preview,
          ordinal = item.preview,
        }
      end,
    }),
    sorter = conf.generic_sorter(opts),
    previewer = previewers.new_buffer_previewer({
      define_preview = function(self, entry)
        local ok, lines = pcall(vim.fn.readfile, entry.value)
        if not ok then
          lines = {}
        end
        vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
        vim.bo[self.state.bufnr].filetype = 'markdown'
      end,
    }),
    attach_mappings = function(_, map)
      map({ 'i', 'n' }, '<CR>', function(bufnr)
        local selection = action_state.get_selected_entry()
        actions.close(bufnr)
        P.open_chat_file(selection.value)
      end)
      return true
    end,
  }):find()
end

return telescope.register_extension({
  exports = { chats = M.chats },
})
