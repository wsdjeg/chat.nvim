-- test/picker_chat_trash_spec.lua
-- The chat_trash picker source lists soft-deleted sessions and offers the two
-- actions that matter there: restore (<C-r>) and purge for good (<C-d>).
--
-- picker.nvim is not a test dependency, so its previewer module is stubbed.
-- preview() only writes into that module, so the assertions below read
-- buflines instead of driving a real preview window.

local previewer_stub = { preview = function() end }
package.loaded['picker.previewer.buffer'] = previewer_stub

local lu = require('luaunit')

local source = require('picker.sources.chat_trash')
local sessions = require('chat.sessions')
local config = require('chat.config')
local windows = require('chat.windows')
local chat = require('chat')
local log = require('chat.log')

TestPickerChatTrash = {}

function TestPickerChatTrash:setUp()
  -- Independent storage: set_cache_dir() derives the matching
  -- sessions-trash/ next to it, so nothing here touches real user data.
  self.dir = vim.fn.tempname() .. '/sessions/'
  vim.fn.mkdir(self.dir, 'p')
  sessions.set_cache_dir(self.dir)

  config.setup({ provider = 'test-provider', model = 'test-model' })
  config.setup({ sessions = { trash = true } })

  -- delete() asks the desktop which session is current; a scripted call has
  -- no window, and forcing nil keeps the fallback branch out of the way.
  self.current_session = windows.current_session
  windows.current_session = function()
    return nil
  end

  self.notified = {}
  self.log_notify = log.notify
  log.notify = function(msg)
    table.insert(self.notified, tostring(msg))
  end

  -- restore() switches to the restored session, which would open real
  -- windows: record the calls instead.
  self.chat_open = chat.open
  self.opened = {}
  chat.open = function(opt)
    table.insert(self.opened, opt)
  end

  -- The source captured `sessions.purge_trash` when it was loaded, so a
  -- failing purge has to be stubbed on that table, not on storage.
  self.purge_trash = sessions.purge_trash

  -- A confirmation prompt waits for keyboard input, which a headless run
  -- never delivers, so every purge test replaces this.
  self.confirm_purge = source.confirm_purge
end

function TestPickerChatTrash:tearDown()
  windows.current_session = self.current_session
  log.notify = self.log_notify
  chat.open = self.chat_open
  sessions.purge_trash = self.purge_trash
  source.confirm_purge = self.confirm_purge
  config.setup({ sessions = { trash = true } })

  for _, dir in ipairs({ self.dir, self.dir:gsub('/+$', '') .. '-trash/' }) do
    if vim.fn.isdirectory(dir) == 1 then
      vim.fn.delete(dir, 'rf')
    end
  end
end

--- Create a session, optionally title it, then soft-delete it.
--- @param id string Session id
--- @param title? string Session title
--- @return table entry Trash entry from sessions.list_trash()
local function make_trashed(id, title)
  sessions.new_with_id(id)
  sessions.append_message(id, {
    role = 'user',
    content = 'hello from ' .. id,
    created = os.time(),
  })
  if title then
    sessions.set_session_title(id, title)
  end
  sessions.write_cache(id)
  sessions.delete(id)
  return sessions.list_trash()[1]
end

-- ─── listing ───────────────────────────────────────────────────

function TestPickerChatTrash:testGetIsEmptyWithoutTrashDirectory()
  lu.assertEquals({}, source.get())
end

function TestPickerChatTrash:testGetListsTrashedSessions()
  local id = '2020-01-01-00-00-01'
  local entry = make_trashed(id, 'Deleted Chat')

  local items = source.get()

  lu.assertEquals(1, #items)
  -- The path, not the id: only a path tells two snapshots of the same id apart.
  lu.assertEquals(entry.path, items[1].value)
  lu.assertEquals(id, items[1].entry.id)
  lu.assertStrContains(items[1].str, 'Deleted Chat')
  -- `[<deleted_at>] <title>`: the timestamp prefix is the deletion marker.
  lu.assertStrContains(items[1].str, '] ')
end

function TestPickerChatTrash:testGetFallsBackToFirstMessageWithoutTitle()
  local id = '2020-01-01-00-00-02'
  make_trashed(id)

  local items = source.get()

  lu.assertEquals(1, #items)
  lu.assertStrContains(items[1].str, 'hello from ' .. id)
end

function TestPickerChatTrash:testGetListsNewestFirst()
  local older = make_trashed('2020-01-01-00-00-03')
  local newer = make_trashed('2021-01-01-00-00-01')

  local items = source.get()

  lu.assertEquals(2, #items)
  lu.assertEquals(newer.path, items[1].value)
  lu.assertEquals(older.path, items[2].value)
end

-- ─── keymaps ───────────────────────────────────────────────────

function TestPickerChatTrash:testActionsExposeRestoreAndPurge()
  local actions = source.actions()

  lu.assertNotNil(actions['<C-r>'])
  lu.assertNotNil(actions['<C-d>'])
  lu.assertNotNil(actions['<C-t>'])
end

function TestPickerChatTrash:testRedrawActionsPurgeWithoutClosing()
  -- purge stays on a redraw mapping so several files can be removed in one
  -- go; restore switches to the session and must close the picker instead.
  local redraw = source.redraw_actions()

  lu.assertNotNil(redraw['<C-d>'])
  lu.assertNil(redraw['<C-r>'])
  lu.assertNil(redraw['<C-t>'])
end

-- ─── restore ──────────────────────────────────────────────────

function TestPickerChatTrash:testRestoreActionRestoresAndOpensSession()
  local id = '2020-01-01-00-00-04'
  local entry = make_trashed(id)

  source.actions()['<C-r>']({ value = entry.path, entry = entry })

  lu.assertEquals(1, #self.opened)
  lu.assertEquals(id, self.opened[1].session)
  lu.assertNotNil(sessions.get()[id])
  lu.assertEquals({}, sessions.list_trash())
end

function TestPickerChatTrash:testRestoreActionNotifiesOnFailure()
  local entry = make_trashed('2020-01-01-00-00-05')
  -- Stale entry: the file disappeared between listing and restoring.
  vim.fn.delete(entry.path)

  source.actions()['<C-r>']({ value = entry.path, entry = entry })

  lu.assertEquals(0, #self.opened)
  lu.assertStrContains(table.concat(self.notified, '\n'), 'Failed to restore')
end

function TestPickerChatTrash:testDefaultActionRestores()
  local id = '2020-01-01-00-00-06'
  local entry = make_trashed(id)

  source.default_action({ value = entry.path, entry = entry })

  lu.assertEquals(1, #self.opened)
  lu.assertEquals(id, self.opened[1].session)
end

-- ─── purge ────────────────────────────────────────────────────

function TestPickerChatTrash:testPurgeActionDeletesAfterConfirmation()
  local id = '2020-01-01-00-00-07'
  local entry = make_trashed(id)
  source.confirm_purge = function()
    return true
  end

  local purged =
    source.actions()['<C-d>']({ value = entry.path, entry = entry })

  lu.assertTrue(purged)
  lu.assertEquals(0, vim.fn.filereadable(entry.path))
  lu.assertEquals({}, sessions.list_trash())
  lu.assertStrContains(
    table.concat(self.notified, '\n'),
    'Deleted permanently'
  )
end

function TestPickerChatTrash:testPurgeActionKeepsFileWhenDeclined()
  local entry = make_trashed('2020-01-01-00-00-08')
  source.confirm_purge = function()
    return false
  end

  local purged =
    source.actions()['<C-d>']({ value = entry.path, entry = entry })

  lu.assertFalse(purged)
  lu.assertEquals(1, vim.fn.filereadable(entry.path))
  lu.assertEquals(1, #sessions.list_trash())
  -- Declining is not an error, so nothing is reported.
  lu.assertEquals('', table.concat(self.notified, '\n'))
end

function TestPickerChatTrash:testPurgeWithoutEntryIsNoop()
  -- redraw_actions() also runs when the filtered list is empty, and then it
  -- calls the action with no argument at all.
  local purged = source.redraw_actions()['<C-d>']()

  lu.assertFalse(purged)
end

function TestPickerChatTrash:testPurgeFailureKeepsFileAndNotifies()
  -- purge_trash() can refuse (a read-only file, say). The file must stay and
  -- the failure must be reported, so the user can retry instead of assuming
  -- the entry is gone.
  local entry = make_trashed('2020-01-01-00-00-09')
  source.confirm_purge = function()
    return true
  end
  sessions.purge_trash = function()
    return false, 'permission denied'
  end

  local purged =
    source.actions()['<C-d>']({ value = entry.path, entry = entry })

  lu.assertFalse(purged)
  lu.assertEquals(1, vim.fn.filereadable(entry.path))
  lu.assertStrContains(table.concat(self.notified, '\n'), 'permission denied')
end

-- ─── preview ──────────────────────────────────────────────────

function TestPickerChatTrash:testPreviewRendersTrashedMessages()
  local id = '2020-01-01-00-00-10'
  local entry = make_trashed(id)

  previewer_stub.buflines = nil
  source.preview({ value = entry.path, entry = entry }, 1, 1)

  lu.assertStrContains(
    table.concat(previewer_stub.buflines, '\n'),
    'hello from ' .. id
  )
  lu.assertEquals('markdown', previewer_stub.filetype)
end

function TestPickerChatTrash:testPreviewFallsBackForUnreadableFile()
  local path = self.dir:gsub('/+$', '') .. '-trash/2020-01-01-00-00-11.json'
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  vim.fn.writefile({ 'not json' }, path)

  previewer_stub.buflines = nil
  source.preview({ value = path }, 1, 1)

  lu.assertEquals('## Unreadable trash file', previewer_stub.buflines[1])
  lu.assertEquals(path, previewer_stub.buflines[3])
end

return TestPickerChatTrash

