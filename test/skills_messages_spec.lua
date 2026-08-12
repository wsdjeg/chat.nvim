-- test/skills_messages_spec.lua
local lu = require('luaunit')
local skills = require('chat.skills')
local config = require('chat.config')

TestSkillsMessages = {}

function TestSkillsMessages:setUp()
  config.setup({
    provider = 'test-provider',
    model = 'test-model',
  })
  for _, s in ipairs(skills.list()) do
    skills.unregister(s.name)
  end
  skills.init()
end

function TestSkillsMessages:tearDown()
  -- Restore real messages
  vim.o.more = true
end

function TestSkillsMessages:testSkillRegistered()
  lu.assertNotNil(skills.get('messages'))
end

function TestSkillsMessages:testSkillProperties()
  local skill = skills.get('messages')
  lu.assertEquals(skill.name, 'messages')
  lu.assertTrue(#skill.description > 0)
  lu.assertEquals(type(skill.handler), 'function')
end

function TestSkillsMessages:testDispatchWithMessages()
  -- Inject a fake message into Neovim's message history
  vim.api.nvim_echo({ { 'Test error message from spec', 'ErrorMsg' } }, true, {})

  local result = skills.dispatch('/messages', 'session-1')
  lu.assertEquals(type(result), 'table')
  lu.assertNotNil(result.content)
  lu.assertEquals(result.role, 'user')
  lu.assertTrue(result.request)
  -- Content should mention the fake message
  lu.assertNotNil(result.content:match('Test error message from spec'))
end

function TestSkillsMessages:testDispatchEmptyMessages()
  -- Clear all messages
  vim.fn.execute('messages clear')

  local result = skills.dispatch('/messages', 'session-1')
  lu.assertEquals(type(result), 'string')
  lu.assertNotNil(result:match('empty'))
end

function TestSkillsMessages:testDispatchContentStructure()
  -- Inject a message
  vim.api.nvim_echo({ { 'Something went wrong', 'WarningMsg' } }, true, {})

  local result = skills.dispatch('/messages', 'session-1')
  lu.assertEquals(type(result), 'table')
  -- Content should contain markdown code block
  lu.assertNotNil(result.content:match('```'))
  -- Content should mention Neovim
  lu.assertNotNil(result.content:match('Neovim'))
end

return TestSkillsMessages

