-- test/util_spec.lua
local lu = require('luaunit')
local util = require('chat.util')

TestUtil = {}

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

-- sanitize_utf8 tests

function TestUtil:testSanitizeUtf8PureASCII()
  local s = 'Hello, World!'
  local sanitized, had_invalid = util.sanitize_utf8(s)
  lu.assertEquals(sanitized, 'Hello, World!')
  lu.assertFalse(had_invalid)
end

function TestUtil:testSanitizeUtf8ValidUTF8()
  -- "你好世界" in UTF-8
  local s = '你好世界'
  local sanitized, had_invalid = util.sanitize_utf8(s)
  lu.assertEquals(sanitized, s)
  lu.assertFalse(had_invalid)
end

function TestUtil:testSanitizeUtf8ValidEmoji()
  -- 4-byte UTF-8: 😀 (U+1F600)
  local s = 'Hello 😀 World'
  local sanitized, had_invalid = util.sanitize_utf8(s)
  lu.assertEquals(sanitized, s)
  lu.assertFalse(had_invalid)
end

function TestUtil:testSanitizeUtf8EmptyString()
  local sanitized, had_invalid = util.sanitize_utf8('')
  lu.assertEquals(sanitized, '')
  lu.assertFalse(had_invalid)
end

function TestUtil:testSanitizeUtf8Nil()
  local sanitized, had_invalid = util.sanitize_utf8(nil)
  lu.assertIsNil(sanitized)
  lu.assertFalse(had_invalid)
end

function TestUtil:testSanitizeUtf8InvalidBytes()
  -- \xFF and \xFE are invalid UTF-8 leading bytes
  local s = 'Hello \xFF\xFE World'
  local sanitized, had_invalid = util.sanitize_utf8(s)
  lu.assertTrue(had_invalid)
  -- Should contain replacement characters (U+FFFD = \xEF\xBF\xBD)
  lu.assertStrContains(sanitized, 'Hello ')
  lu.assertStrContains(sanitized, ' World')
  -- Should NOT contain the original invalid bytes
  lu.assertEquals(string.find(sanitized, '\xFF'), nil)
  lu.assertEquals(string.find(sanitized, '\xFE'), nil)
end

function TestUtil:testSanitizeUtf8TruncatedSequence()
  -- 2-byte sequence truncated (0xC3 without continuation byte)
  local s = 'abc\xC3'
  local sanitized, had_invalid = util.sanitize_utf8(s)
  lu.assertTrue(had_invalid)
  lu.assertStrContains(sanitized, 'abc')
  -- The truncated byte should be replaced
  lu.assertEquals(string.find(sanitized, '\xC3'), nil)
end

function TestUtil:testSanitizeUtf8LoneContinuationByte()
  -- 0x80 is a continuation byte without a leading byte
  local s = 'a\x80b'
  local sanitized, had_invalid = util.sanitize_utf8(s)
  lu.assertTrue(had_invalid)
  lu.assertStrContains(sanitized, 'a')
  lu.assertStrContains(sanitized, 'b')
  lu.assertEquals(string.find(sanitized, '\x80'), nil)
end

function TestUtil:testSanitizeUtf8OverlongEncoding()
  -- 0xC0 0x80 is an overlong encoding of U+0000
  local s = 'a\xC0\x80b'
  local sanitized, had_invalid = util.sanitize_utf8(s)
  lu.assertTrue(had_invalid)
  lu.assertStrContains(sanitized, 'a')
  lu.assertStrContains(sanitized, 'b')
  lu.assertEquals(string.find(sanitized, '\xC0\x80'), nil)
end

function TestUtil:testSanitizeUtf8SurrogatePair()
  -- 0xED 0xA0 0x80 is a UTF-8 encoded surrogate (U+D800)
  local s = 'a\xED\xA0\x80b'
  local sanitized, had_invalid = util.sanitize_utf8(s)
  lu.assertTrue(had_invalid)
  lu.assertStrContains(sanitized, 'a')
  lu.assertStrContains(sanitized, 'b')
  lu.assertEquals(string.find(sanitized, '\xED\xA0\x80'), nil)
end

function TestUtil:testSanitizeUtf8MixedValidInvalid()
  -- Mix of valid UTF-8 and invalid bytes
  local s = '你好\xFF世界\xFE'
  local sanitized, had_invalid = util.sanitize_utf8(s)
  lu.assertTrue(had_invalid)
  -- Valid parts should be preserved
  lu.assertStrContains(sanitized, '你好')
  lu.assertStrContains(sanitized, '世界')
  -- Invalid bytes should be gone
  lu.assertEquals(string.find(sanitized, '\xFF'), nil)
  lu.assertEquals(string.find(sanitized, '\xFE'), nil)
end

function TestUtil:testSanitizeUtf8ReplacementChar()
  -- Check that invalid bytes are replaced with U+FFFD (\xEF\xBF\xBD)
  local s = '\xFF'
  local sanitized, had_invalid = util.sanitize_utf8(s)
  lu.assertTrue(had_invalid)
  lu.assertEquals(sanitized, '\xEF\xBF\xBD')
end

function TestUtil:testSanitizeUtf8GBKLikeBytes()
  -- Simulate GBK-encoded "你好" (0xC4 0xE3 0xBA 0xC3)
  -- These are not valid UTF-8 sequences
  local s = '\xC4\xE3\xBA\xC3'
  local sanitized, had_invalid = util.sanitize_utf8(s)
  lu.assertTrue(had_invalid)
  -- Each invalid leading byte should be replaced
  -- \xC4 expects a continuation byte but \xE3 is > 0xBF
  -- All 4 bytes should be replaced
  lu.assertEquals(#sanitized, 4 * 3) -- 4 replacement chars, each 3 bytes
end

function TestUtil:testSanitizeUtf8ValidMultibytePreserved()
  -- Test various valid multi-byte sequences
  -- 2-byte: ñ (U+00F1) = \xC3\xB1
  -- 3-byte: 好 (U+597D) = \xE5\xA5\xBD
  -- 4-byte: 😀 (U+1F600) = \xF0\x9F\x98\x80
  local s = '\xC3\xB1\xE5\xA5\xBD\xF0\x9F\x98\x80'
  local sanitized, had_invalid = util.sanitize_utf8(s)
  lu.assertEquals(sanitized, s)
  lu.assertFalse(had_invalid)
end

return TestUtil

