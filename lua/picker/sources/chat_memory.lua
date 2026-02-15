local M = {}

local previewer = require('picker.previewer.buffer')
local memory = require('chat.memory')

function M.get()
  return vim.tbl_map(function(t)
    return {
      value = t,
      str = vim.split(t.content, '\n')[1],
    }
  end, memory.get_memories())
end

function M.actions()
  return {
    ['<C-d>'] = function(entry)

      memory.delete(entry.value.id)

    end,
  }
end

function M.default_action(item) end

M.preview_win = true

function M.preview(item, win, buf)
  previewer.buflines = vim.split(item.value.content, '\n')
  local line = 1
  previewer.filetype = 'markdown'
  previewer.preview(line, win, buf, true)
end

return M
