local lu = require('luaunit')
local config = require('chat.config')
local share = require('chat.sessions.share')
local storage = require('chat.sessions.storage')

local system_orig = vim.system

TestShare = {}

function TestShare:setUp()
  self.dir = vim.fn.tempname() .. '_share/'
  vim.fn.mkdir(self.dir, 'p')
  storage.set_cache_dir(self.dir)
  config.setup({
    storage_dir = vim.fn.tempname(),
    allowed_path = vim.fs.normalize(vim.fn.getcwd()),
  })
  storage.sessions = {}
end

function TestShare:tearDown()
  vim.system = system_orig
  if vim.fn.isdirectory(self.dir) == 1 then
    vim.fn.delete(self.dir, 'rf')
  end
end

function TestShare:testSaveToFileMissingSession()
  local result = share.save_to_file('nonexistent', self.dir .. '/out.json')
  lu.assertFalse(result)
end

function TestShare:testSaveToFileSuccess()
  storage.sessions['s1'] = { id = 's1', messages = { { role = 'user', content = 'hi' } } }
  local path = self.dir .. '/nested/session.json'
  local result = share.save_to_file('s1', path)
  lu.assertTrue(result)
  lu.assertEquals(1, vim.fn.filereadable(path))
end

function TestShare:testLoadFromFileMissing()
  lu.assertNil(share.load_from_file(self.dir .. '/does_not_exist.json'))
end

function TestShare:testLoadFromFileInvalidJson()
  local path = self.dir .. '/invalid.json'
  vim.fn.writefile({ 'not json' }, path)
  lu.assertNil(share.load_from_file(path))
end

function TestShare:testLoadFromFileNoMessages()
  local path = self.dir .. '/no_messages.json'
  vim.fn.writefile({ vim.json.encode({ id = 'x' }) }, path)
  lu.assertNil(share.load_from_file(path))
end

function TestShare:testLoadFromFileSuccess()
  local path = self.dir .. '/valid.json'
  vim.fn.writefile({ vim.json.encode({ id = 's10', messages = { { role = 'user', content = 'hi' } } }) }, path)
  local id = share.load_from_file(path)
  lu.assertEquals('s10', id)
  lu.assertNotNil(storage.sessions['s10'])
end

function TestShare:testLoadFromFileExistingId()
  storage.sessions['s10'] = { id = 's10', messages = {} }
  local path = self.dir .. '/exist.json'
  vim.fn.writefile({ vim.json.encode({ id = 's10', messages = { { role = 'user', content = 'hi' } } }) }, path)
  local id = share.load_from_file(path)
  lu.assertNotEquals('s10', id)
end

function TestShare:testLoadFromUrlInvalidUrl()
  lu.assertNil(share.load_from_url('not-a-url'))
end

function TestShare:testLoadFromUrlSuccess()
  vim.system = function(cmd, opts)
    return {
      wait = function()
        return {
          code = 0,
          stdout = vim.json.encode({ id = 's_url', messages = { { role = 'user', content = 'hi' } } }),
          stderr = '',
        }
      end,
    }
  end
  local id = share.load_from_url('https://example.com/session.json')
  lu.assertEquals('s_url', id)
end

function TestShare:testLoadFromUrlFailure()
  vim.system = function(cmd, opts)
    return {
      wait = function()
        return { code = 1, stdout = '', stderr = 'failure' }
      end,
    }
  end
  lu.assertNil(share.load_from_url('https://example.com/session.json'))
end

function TestShare:testLoadFromUrlInvalidData()
  vim.system = function(cmd, opts)
    return {
      wait = function()
        return { code = 0, stdout = 'not json', stderr = '' }
      end,
    }
  end
  lu.assertNil(share.load_from_url('https://example.com/session.json'))
end

return TestShare
