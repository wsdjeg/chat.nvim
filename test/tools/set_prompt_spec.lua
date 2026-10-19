local lu = require('luaunit')
local tools = require('chat.tools')
local config = require('chat.config')
local set_prompt = require('chat.tools.set_prompt')
local storage = require('chat.sessions.storage')

TestSetPrompt = {}

function TestSetPrompt:setUp()
  self.cwd = vim.fs.normalize(vim.fn.getcwd())
  config.setup({ allowed_path = self.cwd })
  storage.sessions = {}
end

function TestSetPrompt:tearDown()
  storage.sessions = {}
end

function TestSetPrompt:testMissingFilepath()
  local result = tools.call('set_prompt', {}, { cwd = self.cwd })
  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'required')
end

function TestSetPrompt:testNotReadable()
  local result = tools.call('set_prompt', {
    filepath = self.cwd .. '/does_not_exist.md',
  }, { cwd = self.cwd })
  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'not readable')
end

function TestSetPrompt:testNotAllowedPath()
  local outside = vim.fs.normalize(vim.fn.stdpath('data')) .. '/prompt_out_' .. os.time() .. '.md'
  vim.fn.writefile({ '# prompt' }, outside)
  local result = tools.call('set_prompt', {
    filepath = outside,
  }, { cwd = self.cwd })
  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'not in allowed paths')

  vim.fn.delete(outside, 'rf')
end

function TestSetPrompt:testSuccess()
  local f = self.cwd .. '/test_prompt.md'
  vim.fn.writefile({ '# hello', 'world' }, f)
  storage.sessions['sess1'] = {}

  local result = tools.call('set_prompt', {
    filepath = f,
  }, { cwd = self.cwd, session = 'sess1' })
  lu.assertNotNil(result)
  lu.assertNotNil(result.content)
  lu.assertEquals('# hello\nworld', storage.sessions['sess1'].prompt)

  vim.fn.delete(f, 'rf')
end

function TestSetPrompt:testNoSessionFails()
  local f = self.cwd .. '/test_prompt2.md'
  vim.fn.writefile({ '# hello' }, f)

  local result = tools.call('set_prompt', {
    filepath = f,
  }, { cwd = self.cwd })
  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'Failed to set session prompt')

  vim.fn.delete(f, 'rf')
end

function TestSetPrompt:testInfoDefault()
  local info = set_prompt.info('not json', { cwd = self.cwd })
  lu.assertEquals('set_prompt', info)
end

function TestSetPrompt:testInfoFilepath()
  local info = set_prompt.info(
    vim.json.encode({ filepath = 'AGENTS.md' }),
    { cwd = self.cwd }
  )
  lu.assertStrContains(info, 'set_prompt ')
  lu.assertStrContains(info, 'AGENTS.md')
end

function TestSetPrompt:testScheme()
  local scheme = set_prompt.scheme()
  lu.assertEquals('set_prompt', scheme['function'].name)
  lu.assertNotNil(scheme['function'].parameters.required)
end

return TestSetPrompt
