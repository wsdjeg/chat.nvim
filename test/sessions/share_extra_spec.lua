-- Coverage for chat.sessions.share: the paste.rs upload job (share()),
-- save_to_file failure paths (mkdir/open/encode), unreadable input files,
-- system_prompt function branches and remaining load_from_url branches.

local lu = require('luaunit')
local config = require('chat.config')
local share = require('chat.sessions.share')
local storage = require('chat.sessions.storage')
local job = require('job')

local system_orig = vim.system
local setreg_orig = vim.fn.setreg

TestShareExtra = {}

function TestShareExtra:setUp()
  self.dir = vim.fn.tempname() .. '_share_extra/'
  vim.fn.mkdir(self.dir, 'p')
  storage.set_cache_dir(self.dir)
  config.setup({
    storage_dir = vim.fn.tempname(),
    allowed_path = vim.fs.normalize(vim.fn.getcwd()),
  })
  storage.sessions = {}

  self.system_prompt_orig = config.config.system_prompt
  self.setreg_calls = {}
  vim.fn.setreg = function(reg, value)
    table.insert(self.setreg_calls, { reg = reg, value = value })
  end

  job.intercept()
end

function TestShareExtra:tearDown()
  vim.system = system_orig
  vim.fn.setreg = setreg_orig
  config.config.system_prompt = self.system_prompt_orig
  job.reset()
  if vim.fn.isdirectory(self.dir) == 1 then
    vim.fn.delete(self.dir, 'rf')
  end
end

local function add_session(id)
  storage.sessions[id] = {
    id = id,
    messages = { { role = 'user', content = 'hi' } },
  }
end

-- share() -----------------------------------------------------------------

function TestShareExtra:testShareMissingSessionReturnsNil()
  lu.assertNil(share.share('nope'))
end

function TestShareExtra:testShareUploadsViaCurlJob()
  add_session('s1')
  share.share('s1')
  local jobid = 1
  -- stdin body was sent and closed
  lu.assertNotNil(job.jobs[jobid])
  lu.assertEquals(1, #job.jobs[jobid].stdin)
  local body = job.jobs[jobid].stdin[1]
  lu.assertStrContains(body, '"id":"s1"')
  lu.assertTrue(job.jobs[jobid].stdin_closed)

  job.emit_stdout(jobid, { 'https://paste.rs/abc123', '201' })
  job.emit_exit(jobid, 0, 0)

  lu.assertEquals(1, #self.setreg_calls)
  lu.assertEquals('+', self.setreg_calls[1].reg)
  lu.assertEquals('https://paste.rs/abc123', self.setreg_calls[1].value)
end

function TestShareExtra:testShareHttpErrorKeepsClipboard()
  add_session('s1')
  share.share('s1')
  job.emit_stdout(1, { 'err body', '500' })
  job.emit_exit(1, 0, 0)
  lu.assertEquals(0, #self.setreg_calls)
end

function TestShareExtra:testShareNoHttpCodeKeepsClipboard()
  add_session('s1')
  share.share('s1')
  job.emit_stdout(1, { 'no status line here' })
  job.emit_exit(1, 0, 0)
  lu.assertEquals(0, #self.setreg_calls)
end

function TestShareExtra:testShareCurlExitErrorKeepsClipboard()
  add_session('s1')
  share.share('s1')
  job.emit_stderr(1, { 'curl: (7) connection refused' })
  job.emit_exit(1, 7, 0)
  lu.assertEquals(0, #self.setreg_calls)
end

function TestShareExtra:testShareCurlSignalErrorKeepsClipboard()
  add_session('s1')
  share.share('s1')
  job.emit_exit(1, 0, 9)
  lu.assertEquals(0, #self.setreg_calls)
end

-- save_to_file ------------------------------------------------------------

function TestShareExtra:testSaveToDirectoryPathFails()
  add_session('s1')
  -- target path is an existing directory: io.open(dir, 'w') fails
  lu.assertFalse(share.save_to_file('s1', self.dir))
end

function TestShareExtra:testSaveMkdirFailureFails()
  add_session('s1')
  local blocking_file = self.dir .. '/blocker'
  vim.fn.writefile({ 'x' }, blocking_file)
  -- parent "directory" path traverses through a regular file: mkdir fails
  local result = share.save_to_file('s1', blocking_file .. '/sub/session.json')
  lu.assertFalse(result)
end

function TestShareExtra:testSaveUndecodableSessionFails()
  storage.sessions['s1'] = {
    id = 's1',
    messages = {},
    fn_field = function() end, -- vim.json.encode cannot serialize functions
  }
  lu.assertFalse(share.save_to_file('s1', self.dir .. '/out.json'))
end

function TestShareExtra:testLoadUnreadableFileReturnsNil()
  if vim.fn.has('win32') == 1 then
    -- chmod 000 does not block reading on Windows; skip there
    return
  end
  local path = self.dir .. '/locked.json'
  vim.fn.writefile({ vim.json.encode({ id = 'x', messages = {} }) }, path)
  vim.fn.setfperm(path, '---------')
  lu.assertNil(share.load_from_file(path))
  vim.fn.setfperm(path, 'rw-r--r--')
end

-- system_prompt function branches (via load_from_file) ---------------------

function TestShareExtra:testLoadUsesSystemPromptFunction()
  config.config.system_prompt = function()
    return 'prompt from fn'
  end
  local path = self.dir .. '/valid.json'
  vim.fn.writefile(
    { vim.json.encode({ id = 'sp1', messages = { { role = 'user', content = 'hi' } } }) },
    path
  )
  local id = share.load_from_file(path)
  lu.assertEquals('sp1', id)
  lu.assertEquals('prompt from fn', storage.sessions['sp1'].prompt)
end

function TestShareExtra:testLoadUsesSystemPromptNonString()
  config.config.system_prompt = function()
    return 7
  end
  local path = self.dir .. '/valid.json'
  vim.fn.writefile(
    { vim.json.encode({ id = 'sp2', messages = { { role = 'user', content = 'hi' } } }) },
    path
  )
  local id = share.load_from_file(path)
  lu.assertEquals('sp2', id)
  lu.assertEquals('7', storage.sessions['sp2'].prompt)
end

function TestShareExtra:testLoadUsesSystemPromptError()
  config.config.system_prompt = function()
    error('broken prompt')
  end
  local path = self.dir .. '/valid.json'
  vim.fn.writefile(
    { vim.json.encode({ id = 'sp3', messages = { { role = 'user', content = 'hi' } } }) },
    path
  )
  local id = share.load_from_file(path)
  lu.assertEquals('sp3', id)
  lu.assertEquals('', storage.sessions['sp3'].prompt)
end

function TestShareExtra:testLoadFromFileWithoutIdGeneratesTimestamp()
  local path = self.dir .. '/no_id.json'
  vim.fn.writefile(
    { vim.json.encode({ messages = { { role = 'user', content = 'hi' } } }) },
    path
  )
  local id = share.load_from_file(path)
  lu.assertNotNil(id)
  lu.assertNotNil(id:match('^%d%d%d%d%-%d%d%-%d%d%-%d%d%-%d%d%-%d%d$'))
  storage.sessions[id] = nil
end

-- load_from_url -------------------------------------------------------------

function TestShareExtra:testLoadFromUrlMissingMessagesReturnsNil()
  vim.system = function(_, _)
    return {
      wait = function()
        return {
          code = 0,
          stdout = vim.json.encode({ id = 'no-msgs' }),
          stderr = '',
        }
      end,
    }
  end
  lu.assertNil(share.load_from_url('https://example.com/s.json'))
end

function TestShareExtra:testLoadFromUrlExistingIdGeneratesNew()
  storage.sessions['dup-url'] = { id = 'dup-url', messages = {} }
  vim.system = function(_, _)
    return {
      wait = function()
        return {
          code = 0,
          stdout = vim.json.encode({
            id = 'dup-url',
            messages = { { role = 'user', content = 'hi' } },
          }),
          stderr = '',
        }
      end,
    }
  end
  local id = share.load_from_url('https://example.com/s.json')
  lu.assertNotNil(id)
  lu.assertNotEquals('dup-url', id)
  storage.sessions[id] = nil
end

function TestShareExtra:testLoadFromUrlEmptyStdoutReturnsNil()
  vim.system = function(_, _)
    return {
      wait = function()
        return { code = 0, stdout = '', stderr = '' }
      end,
    }
  end
  lu.assertNil(share.load_from_url('https://example.com/s.json'))
end

return TestShareExtra

