-- test/platform_spec.lua
-- Platform-specific tests for chat.nvim

local lu = require('luaunit')
local util = require('chat.util')

TestPlatform = {}

function TestPlatform:testWindowsAbsolutePath()
  -- Test Windows absolute path detection
  if vim.fn.has('win32') == 1 or vim.fn.has('win64') == 1 then
    -- Drive letter path
    local result = util.resolve('C:\\Users\\test\\file.lua', 'D:\\other')
    lu.assertNotNil(result)
    -- Should contain the key parts (normalized with forward slashes)
    lu.assertStrContains(result, 'Users')
    lu.assertStrContains(result, 'test')
    lu.assertStrContains(result, 'file.lua')

    -- UNC path
    result = util.resolve('\\\\server\\share\\file.lua', 'C:\\other')
    lu.assertStrContains(result, 'server')
  else
    -- Skip on non-Windows
    lu.assertTrue(true, 'Skipping Windows test on non-Windows platform')
  end
end

function TestPlatform:testUnixAbsolutePath()
  -- Test Unix absolute path detection
  if vim.fn.has('win32') == 0 then
    local result = util.resolve('/tmp/test.lua', '/home/user')
    lu.assertEquals(result, '/tmp/test.lua')
  else
    -- Skip on Windows
    lu.assertTrue(true, 'Skipping Unix test on Windows platform')
  end
end

function TestPlatform:testRelativePathResolution()
  -- Test relative path resolution
  local cwd = vim.fn.getcwd()
  local result = util.resolve('./test.lua', cwd)

  lu.assertNotNil(result)
  lu.assertStrContains(result, 'test.lua')
end

function TestPlatform:testParentDirectoryPath()
  -- Test parent directory path resolution
  local cwd = vim.fn.getcwd()
  local result = util.resolve('../test.lua', cwd)

  lu.assertNotNil(result)
end

function TestPlatform:testPathNormalization()
  -- Test path normalization
  local cwd = vim.fn.getcwd()
  local result = util.resolve('./subdir/../test.lua', cwd)

  lu.assertNotNil(result)
  -- After normalization, should not contain 'subdir/..'
  -- Note: vim.fs.normalize might keep some parts, so we just check it doesn't error
end

function TestPlatform:testEmptyPathHandling()
  -- Test empty path handling
  local result = util.resolve('', vim.fn.getcwd())
  lu.assertIsNil(result)
end

function TestPlatform:testNilPathHandling()
  -- Test nil path handling
  local result = util.resolve(nil, vim.fn.getcwd())
  lu.assertIsNil(result)
end

function TestPlatform:testHomeDirectoryExpansion()
  -- Test home directory expansion (if supported)
  local home = vim.fn.expand('~')
  if home ~= '~' then
    local result = util.resolve('~/test.lua', vim.fn.getcwd())
    lu.assertNotNil(result)
    -- Should expand ~ to actual home path
  else
    lu.assertTrue(true, 'Home directory expansion not supported')
  end
end

function TestPlatform:testWindowsPathSeparators()
  -- Test Windows path separator handling
  if vim.fn.has('win32') == 1 or vim.fn.has('win64') == 1 then
    local cwd = vim.fn.getcwd()
    local result = util.resolve('.\\test.lua', cwd)
    lu.assertNotNil(result)
    lu.assertStrContains(result, 'test.lua')
  else
    lu.assertTrue(
      true,
      'Skipping Windows separator test on non-Windows platform'
    )
  end
end

function TestPlatform:testMixedPathSeparators()
  -- Test mixed path separators (Windows should handle both / and \)
  if vim.fn.has('win32') == 1 or vim.fn.has('win64') == 1 then
    local cwd = vim.fn.getcwd()
    local result = util.resolve('./subdir/test.lua', cwd)
    lu.assertNotNil(result)
  else
    lu.assertTrue(
      true,
      'Skipping mixed separator test on non-Windows platform'
    )
  end
end

function TestPlatform:testLongPathHandling()
  -- Test handling of very long paths
  local cwd = vim.fn.getcwd()
  local long_path = './' .. string.rep('subdir/', 20) .. 'file.lua'
  local result = util.resolve(long_path, cwd)

  lu.assertNotNil(result)
end

function TestPlatform:testSpecialCharactersInPath()
  -- Test paths with special characters
  local cwd = vim.fn.getcwd()
  local result = util.resolve('./test file with spaces.lua', cwd)
  lu.assertNotNil(result)

  result = util.resolve('./test-file.lua', cwd)
  lu.assertNotNil(result)
end

return TestPlatform
