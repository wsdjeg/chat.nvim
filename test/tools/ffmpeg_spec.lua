local lu = require('luaunit')
local tools = require('chat.tools')
local config = require('chat.config')

TestFfmpeg = {}

function TestFfmpeg:setUp()
  self.test_dir = vim.fs.normalize(vim.fn.getcwd()) .. '/test_temp_ffmpeg'
  if vim.fn.isdirectory(self.test_dir) == 0 then
    vim.fn.mkdir(self.test_dir, 'p')
  end

  config.setup({
    allowed_path = vim.fs.normalize(vim.fn.getcwd()),
  })
end

function TestFfmpeg:tearDown()
  if self.test_dir and vim.fn.isdirectory(self.test_dir) == 1 then
    vim.fn.delete(self.test_dir, 'rf')
  end
end

-- ============================
-- Scheme Tests
-- ============================

function TestFfmpeg:testScheme()
  local ffmpeg = require('chat.tools.ffmpeg')
  local scheme = ffmpeg.scheme()

  lu.assertNotNil(scheme)
  lu.assertEquals(scheme.type, 'function')
  lu.assertEquals(scheme['function'].name, 'ffmpeg')
  lu.assertEquals(scheme['function'].parameters.type, 'object')

  local required = scheme['function'].parameters.required
  lu.assertTrue(vim.tbl_contains(required, 'input'))

  -- Should have input, output, quality properties
  local props = scheme['function'].parameters.properties
  lu.assertNotNil(props.input)
  lu.assertNotNil(props.output)
  lu.assertNotNil(props.quality)
end

-- ============================
-- Info Tests
-- ============================

function TestFfmpeg:testInfoBasic()
  local ffmpeg = require('chat.tools.ffmpeg')
  local info = ffmpeg.info(
    '{"input":"./photo.png"}',
    { cwd = '/test' }
  )

  lu.assertNotNil(info)
  lu.assertStrContains(info, 'ffmpeg')
  lu.assertStrContains(info, 'photo.png')
end

function TestFfmpeg:testInfoWithQuality()
  local ffmpeg = require('chat.tools.ffmpeg')
  local info = ffmpeg.info(
    '{"input":"./photo.png","quality":60}',
    { cwd = '/test' }
  )

  lu.assertNotNil(info)
  lu.assertStrContains(info, 'quality=60')
end

function TestFfmpeg:testInfoWithOutput()
  local ffmpeg = require('chat.tools.ffmpeg')
  local info = ffmpeg.info(
    '{"input":"./photo.png","output":"./out.webp"}',
    { cwd = '/test' }
  )

  lu.assertNotNil(info)
  lu.assertStrContains(info, 'output=')
  lu.assertStrContains(info, 'out.webp')
end

function TestFfmpeg:testInfoInvalidJson()
  local ffmpeg = require('chat.tools.ffmpeg')
  local info = ffmpeg.info('invalid json', { cwd = '/test' })
  lu.assertEquals(info, 'ffmpeg')
end

-- ============================
-- Registration Test
-- ============================

function TestFfmpeg:testRegistered()
  local available = tools.available_tools()
  local tool_names = {}
  for _, tool in ipairs(available) do
    table.insert(tool_names, tool['function'].name)
  end

  lu.assertTrue(
    vim.tbl_contains(tool_names, 'ffmpeg'),
    'ffmpeg should be in available_tools'
  )
end

-- ============================
-- Validation Tests
-- ============================

function TestFfmpeg:testMissingCwd()
  local result = tools.call('ffmpeg', {
    input = self.test_dir .. '/image.png',
  }, { cwd = '' })

  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'cwd')
end

function TestFfmpeg:testMissingInput()
  local result = tools.call('ffmpeg', {}, {
    cwd = vim.fs.normalize(vim.fn.getcwd()),
  })

  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'input')
end

function TestFfmpeg:testEmptyInput()
  local result = tools.call('ffmpeg', {
    input = '',
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'input')
end

function TestFfmpeg:testInputNotExist()
  local result = tools.call('ffmpeg', {
    input = self.test_dir .. '/nonexistent.png',
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'does not exist')
end

function TestFfmpeg:testUnsupportedFormat()
  -- Create a fake file with unsupported extension
  local input = self.test_dir .. '/file.txt'
  vim.fn.writefile({ 'not an image' }, input)

  local result = tools.call('ffmpeg', {
    input = input,
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'Unsupported')
end

function TestFfmpeg:testInvalidQualityHigh()
  -- Create a dummy png file
  local input = self.test_dir .. '/img.png'
  vim.fn.writefile({ 'dummy' }, input)

  local result = tools.call('ffmpeg', {
    input = input,
    quality = 200,
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'quality')
end

function TestFfmpeg:testInvalidQualityNegative()
  local input = self.test_dir .. '/img2.png'
  vim.fn.writefile({ 'dummy' }, input)

  local result = tools.call('ffmpeg', {
    input = input,
    quality = -10,
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'quality')
end

function TestFfmpeg:testInvalidQualityType()
  local input = self.test_dir .. '/img3.png'
  vim.fn.writefile({ 'dummy' }, input)

  local result = tools.call('ffmpeg', {
    input = input,
    quality = 'high',
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'quality')
end

-- ============================
-- Security Tests
-- ============================

function TestFfmpeg:testSecurityInputOutsideCwd()
  local result = tools.call('ffmpeg', {
    input = '../../../etc/passwd',
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'Security')
end

function TestFfmpeg:testSecurityOutputOutsideCwd()
  local input = self.test_dir .. '/sec.png'
  vim.fn.writefile({ 'dummy' }, input)

  local result = tools.call('ffmpeg', {
    input = input,
    output = '../../../tmp/evil.webp',
  }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'Security')
end

function TestFfmpeg:testSecurityNotAllowedPath()
  local temp_dir = vim.fn.tempname()
  vim.fn.mkdir(temp_dir, 'p')
  local temp_input = temp_dir .. '/image.png'
  vim.fn.writefile({ 'dummy' }, temp_input)

  local result = tools.call('ffmpeg', {
    input = temp_input,
  }, { cwd = temp_dir })

  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'allowed_path')

  vim.fn.delete(temp_dir, 'rf')
end

-- ============================
-- Supported Format Tests
-- ============================

function TestFfmpeg:testSupportedExtensions()
  -- Test that all supported extensions are accepted (will fail at ffmpeg stage,
  -- but should not fail at format validation)
  local supported = { 'png', 'jpg', 'jpeg', 'bmp', 'gif', 'tiff', 'tga', 'webp' }

  for _, ext in ipairs(supported) do
    local input = self.test_dir .. '/test_image.' .. ext
    vim.fn.writefile({ 'dummy' }, input)

    local result = tools.call('ffmpeg', {
      input = input,
    }, { cwd = vim.fs.normalize(vim.fn.getcwd()) })

    -- Should NOT contain "Unsupported" error
    -- (it may fail with ffmpeg error if ffmpeg not installed, or with conversion error)
    if result.error then
      lu.assertFalse(
        string.find(result.error, 'Unsupported') ~= nil,
        'Extension .' .. ext .. ' should be supported'
      )
    end
  end
end

return TestFfmpeg

