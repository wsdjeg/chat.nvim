-- test/util_spec.lua
local lu = require('luaunit')
local util = require('chat.util')

local TestUtil = {}

function TestUtil:testResolveAbsolutePath()
  -- Test absolute path on Unix-like systems
  if vim.fn.has('win32') == 0 then
    local result = util.resolve('/tmp/test.lua', '/home/user')
    lu.assertEquals(result, '/tmp/test.lua')
  end
end

function TestUtil:testResolveRelativePath()
  local result = util.resolve('./test.lua', '/home/user')
  lu.assertStrContains(result, 'test.lua')
end

function TestUtil:testResolveEmptyPath()
  local result = util.resolve('', '/home/user')
  lu.assertIsNil(result)
end

function TestUtil:testResolveNilPath()
  local result = util.resolve(nil, '/home/user')
  lu.assertIsNil(result)
end

function TestUtil:testNormalizePath()
  local result = util.resolve('../test.lua', '/home/user/project')
  lu.assertNotNil(result)
  lu.assertStrContains(result, 'test.lua')
end

return TestUtil
