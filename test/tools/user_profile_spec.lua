-- test/tools/user_profile_spec.lua
local lu = require('luaunit')
local user_profile = require('chat.tools.user_profile')
local user = require('chat.user')
local config = require('chat.config')

TestUserProfileTool = {}

function TestUserProfileTool:setUp()
  local tmp_dir = vim.fn.tempname() .. '_user_profile_tool/'
  config.setup({
    user = {
      enable = true,
      id = 'tooluser',
      storage_dir = tmp_dir,
    },
  })
  vim.fn.mkdir(config.config.user.storage_dir, 'p')
end

function TestUserProfileTool:tearDown()
  vim.fn.delete(config.config.user.storage_dir, 'rf')
end

function TestUserProfileTool:testScheme()
  local scheme = user_profile.scheme()
  lu.assertNotNil(scheme)
  lu.assertEquals(scheme.type, 'function')
  lu.assertEquals(scheme['function'].name, 'user_profile')
  lu.assertNotNil(scheme['function'].parameters)
end

function TestUserProfileTool:testGetAction()
  -- First save a profile
  user.save_profile('tooluser', '# User Profile: tooluser\n\n- Name: Tool User')

  local result = user_profile.user_profile({
    action = 'get',
  }, { session = 'test-session' })

  lu.assertNotNil(result.content)
  local decoded = vim.json.decode(result.content)
  lu.assertEquals(decoded.user_id, 'tooluser')
  lu.assertTrue(decoded.profile:find('Tool User') ~= nil)
end

function TestUserProfileTool:testGetActionNotFound()
  local result = user_profile.user_profile({
    action = 'get',
    user_id = 'nonexistent',
  }, { session = 'test-session' })

  lu.assertNotNil(result.content)
  lu.assertTrue(result.content:find('No profile found') ~= nil)
end

function TestUserProfileTool:testUpdateAction()
  local content = '# User Profile: newuser\n\n## Basic Info\n- Name: New User'
  local result = user_profile.user_profile({
    action = 'update',
    user_id = 'newuser',
    content = content,
  }, { session = 'test-session' })

  lu.assertNotNil(result.content)
  lu.assertTrue(result.content:find('saved successfully') ~= nil)

  -- Verify it was actually saved
  local profile = user.get_profile('newuser')
  lu.assertNotNil(profile)
  lu.assertTrue(profile:find('New User') ~= nil)
end

function TestUserProfileTool:testUpdateActionMissingContent()
  local result = user_profile.user_profile({
    action = 'update',
    user_id = 'newuser',
  }, { session = 'test-session' })

  lu.assertNotNil(result.error)
  lu.assertTrue(result.error:find('content') ~= nil)
end

function TestUserProfileTool:testListAction()
  user.save_profile('alpha', '# Alpha')
  user.save_profile('beta', '# Beta')

  local result = user_profile.user_profile({
    action = 'list',
  }, { session = 'test-session' })

  lu.assertNotNil(result.content)
  local decoded = vim.json.decode(result.content)
  lu.assertEquals(decoded.count, 2)
end

function TestUserProfileTool:testDeleteAction()
  user.save_profile('tempuser', '# temp')

  local result = user_profile.user_profile({
    action = 'delete',
    user_id = 'tempuser',
  }, { session = 'test-session' })

  lu.assertNotNil(result.content)
  lu.assertTrue(result.content:find('deleted') ~= nil)
  lu.assertNil(user.get_profile('tempuser'))
end

function TestUserProfileTool:testDeleteActionNotFound()
  local result = user_profile.user_profile({
    action = 'delete',
    user_id = 'nonexistent',
  }, { session = 'test-session' })

  lu.assertNotNil(result.content)
  lu.assertTrue(result.content:find('No profile found') ~= nil)
end

function TestUserProfileTool:testUnknownAction()
  local result = user_profile.user_profile({
    action = 'unknown',
  }, { session = 'test-session' })

  lu.assertNotNil(result.error)
  lu.assertTrue(result.error:find('Unknown action') ~= nil)
end

function TestUserProfileTool:testInfo()
  local info = user_profile.info({
    action = 'update',
    user_id = 'wsdjeg',
  }, {})
  lu.assertTrue(info:find('update') ~= nil)
  lu.assertTrue(info:find('wsdjeg') ~= nil)
end

function TestUserProfileTool:testInfoDefault()
  local info = user_profile.info({
    action = 'get',
  }, {})
  lu.assertTrue(info:find('get') ~= nil)
end

function TestUserProfileTool:testInfoStringArg()
  local info = user_profile.info('{"action":"list"}', {})
  lu.assertTrue(info:find('list') ~= nil)
end

return TestUserProfileTool

