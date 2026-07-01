-- test/user_spec.lua
local lu = require('luaunit')
local user = require('chat.user')
local config = require('chat.config')

TestUser = {}

function TestUser:setUp()
  local tmp_dir = vim.fn.tempname() .. '_user_profiles/'
  config.setup({
    user = {
      enable = true,
      id = 'testuser',
      storage_dir = tmp_dir,
    },
  })
  vim.fn.mkdir(config.config.user.storage_dir, 'p')
end

function TestUser:tearDown()
  vim.fn.delete(config.config.user.storage_dir, 'rf')
end

function TestUser:testGetUserId()
  local uid = user.get_user_id()
  lu.assertEquals(uid, 'testuser')
end

function TestUser:testGetUserIdEmpty()
  config.setup({
    user = {
      enable = true,
      id = '',
      storage_dir = vim.fn.tempname() .. '_empty/',
    },
  })
  local uid = user.get_user_id()
  lu.assertEquals(uid, '')
end

function TestUser:testGetProfilePath()
  local path = user.get_profile_path('wsdjeg')
  lu.assertTrue(path:match('user%-wsdjeg%.md$') ~= nil)
end

function TestUser:testSanitizeUserId()
  local path = user.get_profile_path('user with spaces')
  lu.assertTrue(path:match('user%-user%-with%-spaces%.md$') ~= nil)
end

function TestUser:testSaveAndGetProfile()
  local content = '# User Profile: testuser\n\n## Basic Info\n- Name: Test User\n'
  local ok = user.save_profile('testuser', content)
  lu.assertTrue(ok)

  local profile = user.get_profile('testuser')
  lu.assertNotNil(profile)
  lu.assertTrue(profile:find('Test User') ~= nil)
end

function TestUser:testGetProfileNotFound()
  local profile = user.get_profile('nonexistent')
  lu.assertNil(profile)
end

function TestUser:testGetProfileEmptyId()
  local profile = user.get_profile('')
  lu.assertNil(profile)
end

function TestUser:testDeleteProfile()
  user.save_profile('tempuser', '# temp')
  lu.assertNotNil(user.get_profile('tempuser'))

  local ok = user.delete_profile('tempuser')
  lu.assertTrue(ok)
  lu.assertNil(user.get_profile('tempuser'))
end

function TestUser:testDeleteProfileNotFound()
  local ok = user.delete_profile('nonexistent')
  lu.assertFalse(ok)
end

function TestUser:testListProfiles()
  user.save_profile('alice', '# Alice')
  user.save_profile('bob', '# Bob')
  user.save_profile('charlie', '# Charlie')

  local profiles = user.list_profiles()
  lu.assertEquals(#profiles, 3)
  -- Should be sorted alphabetically
  lu.assertEquals(profiles[1].id, 'alice')
  lu.assertEquals(profiles[2].id, 'bob')
  lu.assertEquals(profiles[3].id, 'charlie')
end

function TestUser:testListProfilesEmpty()
  local profiles = user.list_profiles()
  lu.assertEquals(#profiles, 0)
end

function TestUser:testGetProfileSystemMessage()
  user.save_profile('testuser', '# User Profile: testuser\n\n- Name: Test')
  local msg = user.get_profile_system_message('testuser')
  lu.assertNotNil(msg)
  lu.assertTrue(msg:find('User Profile') ~= nil)
  lu.assertTrue(msg:find('Test') ~= nil)
end

function TestUser:testGetProfileSystemMessageDisabled()
  config.setup({
    user = {
      enable = false,
      id = 'testuser',
      storage_dir = vim.fn.tempname() .. '_disabled/',
    },
  })
  user.save_profile('testuser', '# test')
  local msg = user.get_profile_system_message('testuser')
  lu.assertNil(msg)
end

function TestUser:testGetProfileSystemMessageNotFound()
  local msg = user.get_profile_system_message('nonexistent')
  lu.assertNil(msg)
end

function TestUser:testGetProfileSystemMessageEmptyId()
  config.setup({
    user = {
      enable = true,
      id = '',
      storage_dir = vim.fn.tempname() .. '_empty_msg/',
    },
  })
  local msg = user.get_profile_system_message()
  lu.assertNil(msg)
end

function TestUser:testSaveProfileEmptyId()
  local ok = user.save_profile('', 'content')
  lu.assertFalse(ok)
end

return TestUser

