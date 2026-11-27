local M = {}

local previewer = require('picker.previewer.buffer')
local sessions = require('chat.sessions')
local formatter = require('chat.formatter')
local log = require('chat.log')

--- Render the deletion timestamp with the configured strftime.
--- @param entry table Trash entry from sessions.list_trash()
--- @return string
local function deleted_text(entry)
  if not entry.deleted_at or entry.deleted_at == 0 then
    return 'unknown'
  end
  return os.date(require('chat.config').config.strftime, entry.deleted_at)
end

--- One-line title: the session title, else the first line of history.
--- @param entry table Trash entry from sessions.list_trash()
--- @return string
local function title_text(entry)
  if entry.title and entry.title ~= '' then
    return entry.title
  end
  return entry.preview or '(empty)'
end

function M.get()
  local items = {}

  for _, entry in ipairs(sessions.list_trash()) do
    local deleted = deleted_text(entry)
    local str = string.format('[%s] %s', deleted, title_text(entry))
    table.insert(items, {
      str = str,
      -- The path, not the id: a session that was deleted twice leaves an
      -- `id-1.json` snapshot behind, and only a path names one of them.
      value = entry.path,
      entry = entry,
      highlight = {
        { 0, 1, 'Comment' },
        { #deleted + 1, #deleted + 2, 'Comment' },
        { 1, #deleted + 1, 'Comment' },
      },
    })
  end

  return items
end

--- Permanently remove one trashed session, after a confirmation.
---
--- Every entry of this source is already deleted, so <C-d> is the last stop:
--- it removes the file for good instead of deleting a session.
--- @param entry table Picker entry
local function purge(entry)
  local ok = vim.fn.confirm(
    string.format('Permanently delete "%s"?', title_text(entry.entry or {})),
    '&Yes\n&No',
    2
  ) == 1
  if not ok then
    return
  end

  local done, err = sessions.purge_trash(entry.value)
  if not done then
    log.notify('Failed to delete: ' .. tostring(err), 'ErrorMsg')
    return
  end
  log.notify(
    'Deleted permanently: ' .. tostring((entry.entry or {}).id or entry.value)
  )
end

function M.actions()
  return {
    ['<C-d>'] = purge,
    ['<C-r>'] = function(entry)
      local id, err = sessions.restore(entry.value)
      if not id then
        log.notify('Failed to restore: ' .. tostring(err), 'ErrorMsg')
        return
      end
      require('chat').open({ session = id })
    end,
    ['<C-t>'] = function(entry)
      -- Inspect the raw cache JSON, or move the file back by hand.
      vim.cmd.tabedit(entry.value)
    end,
  }
end

function M.default_action(item)
  local id, err = sessions.restore(item.value)
  if not id then
    log.notify('Failed to restore: ' .. tostring(err), 'ErrorMsg')
    return
  end
  require('chat').open({ session = id })
end

M.preview_win = true

function M.preview(item, win, buf)
  local payload = sessions.read_trash(item.value)
  local lines
  if payload and type(payload.messages) == 'table' then
    lines = formatter.generate_buffer(
      payload.messages,
      payload.id or (item.entry and item.entry.id)
    )
  else
    lines = { '## Unreadable trash file', '', item.value }
  end
  previewer.buflines = lines
  previewer.filetype = 'markdown'
  previewer.preview(1, win, buf, true)
end

return M

