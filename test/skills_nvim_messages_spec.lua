-- test/skills_nvim_messages_spec.lua
local lu = require('luaunit')
local skills = require('chat.skills')
local config = require('chat.config')

TestSkillsNvimMessages = {}

function TestSkillsNvimMessages:setUp()
  config.setup({
    provider = 'test-provider',
    model = 'test-model',
  })
  for _, s in ipairs(skills.list()) do
    skills.unregister(s.name)
  end
  skills.init()
end

function TestSkillsNvimMessages:tearDown()
  -- Restore real messages
  vim.o.more = true
end

function TestSkillsNvimMessages:testSkillRegistered()
  lu.assertNotNil(skills.get('nvim-messages'))
end

function TestSkillsNvimMessages:testSkillProperties()
  local skill = skills.get('nvim-messages')
  lu.assertEquals(skill.name, 'nvim-messages')
  lu.assertTrue(#skill.description > 0)
  lu.assertEquals(type(skill.handler), 'function')
end

function TestSkillsNvimMessages:testDispatchWithMessages()
  -- Inject a fake message into Neovim's message history
  vim.api.nvim_echo({ { 'Test error message from spec', 'ErrorMsg' } }, true, {})

  local result = skills.dispatch('/nvim-messages', 'session-1')
  lu.assertEquals(type(result), 'table')
  lu.assertNotNil(result.content)
  lu.assertEquals(result.role, 'user')
  lu.assertTrue(result.request)
  -- Content should mention the fake message
  lu.assertNotNil(result.content:match('Test error message from spec'))
end

function TestSkillsNvimMessages:testDispatchEmptyMessages()
  -- Clear all messages
  vim.fn.execute('messages clear')

  local result = skills.dispatch('/nvim-messages', 'session-1')
  lu.assertEquals(type(result), 'string')
  lu.assertNotNil(result:match('empty'))
end

function TestSkillsNvimMessages:testDispatchContentStructure()
  -- Inject a message
  vim.api.nvim_echo({ { 'Something went wrong', 'WarningMsg' } }, true, {})

  local result = skills.dispatch('/nvim-messages', 'session-1')
  lu.assertEquals(type(result), 'table')
  -- Content should contain markdown code block
  lu.assertNotNil(result.content:match('```'))
  -- Content should mention Neovim
  lu.assertNotNil(result.content:match('Neovim'))
end

return TestSkillsNvimMessages

