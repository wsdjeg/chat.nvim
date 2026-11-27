-- test/sessions/trash_spec.lua
-- Soft delete: sessions.delete() moves the cache file into
-- {storage_dir}/sessions-trash/ instead of unlinking it, and
-- list_trash() / restore() / purge_trash() operate on that directory.

local lu = require('luaunit')

local sessions = require('chat.sessions')
local storage = require('chat.sessions.storage')
local config = require('chat.config')
local windows = require('chat.windows')
local skills = require('chat.skills')
local log = require('chat.log')

TestTrash = {}

function TestTrash:setUp()
  -- A temporary sessions/ directory: set_cache_dir() derives the matching
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

  self.moved_to_trash = storage.move_to_trash
  self.notified = {}
  self.log_notify = log.notify
  -- notify() accepts both a string and a list of lines; flatten both so
  -- assertions can just concat the captured channel.
  log.notify = function(msg, _)
    if type(msg) == 'table' then
      for _, line in ipairs(msg) do
        table.insert(self.notified, line)
      end
    else
      table.insert(self.notified, tostring(msg))
    end
  end
end

function TestTrash:tearDown()
  windows.current_session = self.current_session
  storage.move_to_trash = self.moved_to_trash
  log.notify = self.log_notify
  config.setup({ sessions = { trash = true } })

  for _, dir in ipairs({ self.dir, self.dir:gsub('/+$', '') .. '-trash/' }) do
    if vim.fn.isdirectory(dir) == 1 then
      vim.fn.delete(dir, 'rf')
    end
  end
end

--- Create a session with an explicit id and one message, then persist it.
--- @param id string Session id
--- @return string id
local function make_session(id)
  sessions.new_with_id(id)
  sessions.append_message(id, {
    role = 'user',
    content = 'hello from ' .. id,
    created = os.time(),
  })
  sessions.write_cache(id)
  return id
end

-- ─── storage: directory derivation ─────────────────────────────

function TestTrash:testSetCacheDirDerivesTrashDir()
  -- The trash must follow the test cache directory, not storage_dir: a
  -- sibling inside the cache directory would be re-loaded by iter_sessions().
  -- The parentheses matter: gsub returns (string, count), and normalize would
  -- take the count as its `opts` argument and raise.
  local expected = vim.fs.normalize((self.dir:gsub('/+$', ''))) .. '-trash/'
  lu.assertEquals(expected, storage.trash_dir)
  lu.assertNotEquals(
    storage.trash_dir,
    vim.fs.normalize(self.dir) .. 'sessions-trash/'
  )
end

function TestTrash:testListTrashEmptyWhenDirectoryMissing()
  lu.assertEquals({}, sessions.list_trash())
end

-- ─── delete → trash ────────────────────────────────────────────

function TestTrash:testDeleteMovesFileToTrash()
  local id = make_session('2020-01-01-00-00-01')

  sessions.delete(id)

  -- Gone from memory and from the active cache directory ...
  lu.assertNil(storage.sessions[id])
  lu.assertEquals(0, vim.fn.filereadable(self.dir .. id .. '.json'))

  -- ... but present in the trash, with the deletion timestamp recorded.
  local entries = sessions.list_trash()
  lu.assertEquals(1, #entries)
  lu.assertEquals(id, entries[1].id)
  lu.assertEquals(1, entries[1].message_count)
  lu.assertNotNil(entries[1].deleted_at)

  local payload = sessions.read_trash(entries[1].path)
  lu.assertNotNil(payload)
  lu.assertEquals(id, payload.id)
  lu.assertEquals(1, #payload.messages)
  lu.assertEquals('hello from ' .. id, payload.messages[1].content)
  lu.assertNotNil(payload.deleted_at)
end

function TestTrash:testDeleteRemovesFileWhenTrashDisabled()
  config.setup({ sessions = { trash = false } })
  local id = make_session('2020-01-01-00-00-02')

  sessions.delete(id)

  lu.assertNil(storage.sessions[id])
  lu.assertEquals(0, vim.fn.filereadable(self.dir .. id .. '.json'))
  lu.assertEquals({}, sessions.list_trash())
end

function TestTrash:testDeleteWithoutCacheFileOnlyClearsMemory()
  -- A session created but never written to disk: there is no file to move,
  -- and delete must not raise.
  sessions.new_with_id('2020-01-01-00-00-03')
  sessions.delete('2020-01-01-00-00-03')

  lu.assertNil(storage.sessions['2020-01-01-00-00-03'])
  lu.assertEquals({}, sessions.list_trash())
end

function TestTrash:testDeleteMissingSessionIsNoop()
  -- Nothing to delete, nothing in the trash afterwards.
  sessions.delete('2099-12-31-23-59-59')
  lu.assertEquals({}, sessions.list_trash())
end

function TestTrash:testTrashFailureFallsBackToDelete()
  -- A trash that cannot be written must not leave a half-deleted session
  -- (removed from memory, still on disk): fall back to the old behaviour.
  local id = make_session('2020-01-01-00-00-04')
  storage.move_to_trash = function()
    return nil, 'disk full'
  end

  sessions.delete(id)

  lu.assertNil(storage.sessions[id])
  lu.assertEquals(0, vim.fn.filereadable(self.dir .. id .. '.json'))
  -- The user is told the session is gone for good: a log line alone would
  -- leave them believing it is restorable.
  lu.assertStrContains(table.concat(self.notified, '\n'), 'Trash failed')
  lu.assertStrContains(
    table.concat(self.notified, '\n'),
    'deleted permanently'
  )
end

function TestTrash:testIterSessionsIgnoresTrashDir()
  -- Regression: the trash lives outside the globbed directory, so a deleted
  -- session must never come back as an active one after a reload.
  local id = make_session('2020-01-01-00-00-05')
  sessions.delete(id)

  sessions.set_cache_dir(self.dir) -- drops the in-memory table
  for _, _ in sessions.iter_sessions() do
  end

  lu.assertNil(storage.sessions[id])
  lu.assertEquals(1, #sessions.list_trash())
end

-- ─── id recovery and collisions ────────────────────────────────

function TestTrash:testTrashCollisionUsesTildeSuffix()
  local id = '2020-01-01-00-00-06'
  make_session(id)
  sessions.delete(id)

  -- Re-create the same id and delete it again: the earlier snapshot must not
  -- be overwritten.
  make_session(id)
  sessions.delete(id)

  local entries = sessions.list_trash()
  lu.assertEquals(2, #entries)

  -- Both entries report the *session* id. A `-N` suffix would strip the
  -- seconds off a timestamp id (`...-00-00-06` -> `...-00-00`).
  for _, entry in ipairs(entries) do
    lu.assertEquals(id, entry.id)
  end

  -- First deletion keeps the plain name, the second is suffixed.
  local paths = {}
  for _, entry in ipairs(entries) do
    paths[vim.fn.fnamemodify(entry.path, ':t')] = true
  end
  lu.assertTrue(paths[id .. '.json'])
  lu.assertTrue(paths[id .. '~1.json'])
end

function TestTrash:testListTrashSortsNewestFirst()
  local first = make_session('2020-01-01-00-00-07')
  sessions.delete(first)

  local second = make_session('2020-01-01-00-00-08')
  sessions.delete(second)

  -- Both deletions usually land in the same second, and deleted_at then ties.
  -- The listing breaks the tie on the session id (newest timestamp first),
  -- which is deterministic and needs no sleep.
  local entries = sessions.list_trash()
  lu.assertEquals(2, #entries)
  lu.assertEquals(second, entries[1].id)
  lu.assertEquals(first, entries[2].id)
end

function TestTrash:testListTrashReportsTitleAndPreview()
  local id = make_session('2020-01-01-00-00-09')
  sessions.set_session_title(id, 'My Deleted Chat')
  sessions.delete(id)

  local entry = sessions.list_trash()[1]
  lu.assertEquals('My Deleted Chat', entry.title)
  lu.assertEquals('hello from ' .. id, entry.preview)
end

-- ─── restore ───────────────────────────────────────────────────

function TestTrash:testRestoreMovesBackAndLoads()
  local id = make_session('2020-01-01-00-00-10')
  sessions.delete(id)
  local entry = sessions.list_trash()[1]

  local restored, err = sessions.restore(entry.path)

  lu.assertEquals(id, restored)
  lu.assertNil(err)
  lu.assertEquals({}, sessions.list_trash())
  lu.assertEquals(1, vim.fn.filereadable(self.dir .. id .. '.json'))

  -- Loaded into memory immediately, so the caller can switch to it.
  lu.assertNotNil(storage.sessions[id])
  lu.assertEquals(1, #storage.sessions[id].messages)
  lu.assertEquals('hello from ' .. id, storage.sessions[id].messages[1].content)

  -- The deletion marker is dropped: it only exists to sort the trash listing.
  local payload = storage.sessions[id]
  lu.assertNil(payload.deleted_at)
end

function TestTrash:testRestoreBySessionId()
  local id = make_session('2020-01-01-00-00-11')
  sessions.delete(id)

  -- The id, not the file path: /restore accepts what the trash listing shows.
  local restored, err = sessions.restore(id)
  lu.assertEquals(id, restored)
  lu.assertNil(err)
end

function TestTrash:testRestoreRefusesExistingSession()
  local id = make_session('2020-01-01-00-00-12')
  sessions.delete(id)
  local entry = sessions.list_trash()[1]

  -- A live session with the same id already exists again.
  make_session(id)

  local restored, err = sessions.restore(entry.path)
  lu.assertNil(restored)
  lu.assertStrContains(err, 'already exists')
  -- The trash copy is left untouched by the refusal.
  lu.assertEquals(1, vim.fn.filereadable(entry.path))
end

function TestTrash:testRestoreUnknownIdFails()
  local restored, err = sessions.restore('no-such-session')
  lu.assertNil(restored)
  lu.assertStrContains(err, 'not found in trash')
end

function TestTrash:testRestoreInvalidPayloadFails()
  local path = self.dir:gsub('/+$', '') .. '-trash/2020-01-01-00-00-13.json'
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  vim.fn.writefile({ 'not json' }, path)

  local restored, err = sessions.restore(path)
  lu.assertNil(restored)
  lu.assertStrContains(err, 'invalid trash file')
end

function TestTrash:testRestoreTrashWithoutMessagesFails()
  local path = self.dir:gsub('/+$', '') .. '-trash/2020-01-01-00-00-14.json'
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  vim.fn.writefile({ vim.json.encode({ id = '2020-01-01-00-00-14' }) }, path)

  local restored, err = sessions.restore(path)
  lu.assertNil(restored)
  lu.assertStrContains(err, 'missing messages')
end

-- ─── purge ─────────────────────────────────────────────────────

function TestTrash:testPurgeRemovesFile()
  local id = make_session('2020-01-01-00-00-15')
  sessions.delete(id)
  local entry = sessions.list_trash()[1]

  local ok, err = sessions.purge_trash(entry.path)

  lu.assertTrue(ok)
  lu.assertNil(err)
  lu.assertEquals(0, vim.fn.filereadable(entry.path))
  lu.assertEquals({}, sessions.list_trash())
end

function TestTrash:testPurgeUnknownIdFails()
  local ok, err = sessions.purge_trash('no-such-session')
  lu.assertFalse(ok)
  lu.assertStrContains(err, 'not found in trash')
end

-- ─── skills ────────────────────────────────────────────────────

function TestTrash:testTrashSkillOnEmptyTrash()
  skills.init()
  local out = skills._builtin_trash.handler('', { session = 's1' })
  lu.assertNil(out)
  lu.assertStrContains(table.concat(self.notified, '\n'), 'Trash is empty')
end

function TestTrash:testTrashSkillListsSessions()
  skills.init()
  local id = make_session('2020-01-01-00-00-16')
  sessions.set_session_title(id, 'Deleted Chat')
  sessions.delete(id)

  local out = skills._builtin_trash.handler('', { session = 's1' })

  -- State-type receipt: nothing is appended to the session.
  lu.assertNil(out)
  local text = table.concat(self.notified, '\n')
  lu.assertStrContains(text, id)
  lu.assertStrContains(text, 'Deleted Chat')
  lu.assertStrContains(text, '1 session(s)')
end

function TestTrash:testRestoreSkillRestoresAndOpensLocally()
  skills.init()
  local id = make_session('2020-01-01-00-00-17')
  sessions.delete(id)

  local opened = {}
  local opened_orig = windows.open
  windows.open = function(opt)
    table.insert(opened, opt)
  end

  local out = skills._builtin_restore.handler(id, { session = 's1' })

  windows.open = opened_orig

  lu.assertNil(out)
  lu.assertEquals(1, #opened)
  lu.assertEquals(id, opened[1].session)
  lu.assertNotNil(storage.sessions[id])
  lu.assertStrContains(table.concat(self.notified, '\n'), 'restored')
end

function TestTrash:testRestoreSkillUnknownIdNotifiesWarning()
  skills.init()
  local out = skills._builtin_restore.handler(
    'no-such-session',
    { session = 's1' }
  )
  lu.assertNil(out)
  lu.assertStrContains(
    table.concat(self.notified, '\n'),
    'not found in trash'
  )
end

function TestTrash:testRestoreSkillRemoteIsSilentWithoutArgs()
  skills.init()
  local out = skills._builtin_restore.handler('', {
    session = 's1',
    origin = 'http',
  })
  lu.assertNil(out)
  lu.assertEquals(0, #self.notified)
end

function TestTrash:testRestoreSkillCompletesFromTrash()
  skills.init()
  local id = make_session('2020-01-01-00-00-18')
  sessions.delete(id)

  lu.assertEquals({ id }, skills._builtin_restore.complete())
end

function TestTrash:testDeleteReceiptMentionsRestore()
  skills.init()
  local id = make_session('2020-01-01-00-00-19')

  local out = skills._builtin_delete.handler('', { session = id })

  lu.assertNil(out)
  lu.assertStrContains(table.concat(self.notified, '\n'), 'restorable with /restore')
end

return TestTrash

