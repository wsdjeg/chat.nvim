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

-- ========== utf8_truncate tests ==========

function TestUtil:testUtf8TruncateAsciiExact()
  local s = 'Hello World'
  lu.assertEquals(util.utf8_truncate(s, 5), 'Hello')
  lu.assertEquals(util.utf8_truncate(s, 11), 'Hello World')
  lu.assertEquals(util.utf8_truncate(s, 100), 'Hello World')
end

function TestUtil:testUtf8TruncateEmpty()
  lu.assertEquals(util.utf8_truncate('', 10), '')
  lu.assertEquals(util.utf8_truncate(nil, 10), '')
  lu.assertEquals(util.utf8_truncate('abc', 0), '')
end

function TestUtil:testUtf8TruncateChineseNoBreak()
  -- 3 Chinese characters, each 3 bytes = 9 bytes total
  -- 你好世界 = \xE4\xBD\xA0 \xE5\xA5\xBD \xE4\xB8\x96 \xE7\x95\x8C
  local s = '你好世界'
  lu.assertEquals(#s, 12) -- 4 chars * 3 bytes

  -- Truncate at 10 bytes: would split 4th char (bytes 10-12)
  -- Should cut back to byte 9 (end of 3rd char)
  local truncated = util.utf8_truncate(s, 10)
  lu.assertEquals(truncated, '你好世')
  lu.assertEquals(#truncated, 9)

  -- Truncate at 9 bytes: exactly end of 3rd char
  lu.assertEquals(util.utf8_truncate(s, 9), '你好世')

  -- Truncate at 8 bytes: would split 3rd char (bytes 7-9)
  -- Should cut back to byte 6 (end of 2nd char)
  lu.assertEquals(util.utf8_truncate(s, 8), '你好')
end

function TestUtil:testUtf8TruncateMixedContent()
  -- ASCII + Chinese mix
  local s = 'AB你好'
  -- A(1) B(1) 你(3) 好(3) = 8 bytes total
  lu.assertEquals(#s, 8)

  -- Truncate at 4: would split 你 (bytes 3-5), cut to 2
  lu.assertEquals(util.utf8_truncate(s, 4), 'AB')
  -- Truncate at 5: end of 你
  lu.assertEquals(util.utf8_truncate(s, 5), 'AB你')
  -- Truncate at 6: would split 好 (bytes 6-8), cut to 5
  lu.assertEquals(util.utf8_truncate(s, 6), 'AB你')
  -- Truncate at 8: full string
  lu.assertEquals(util.utf8_truncate(s, 8), 'AB你好')
end

function TestUtil:testUtf8Truncate4ByteEmoji()
  -- 😀 = \xF0\x9F\x98\x80 (4 bytes)
  local s = 'A😀B'
  -- A(1) 😀(4) B(1) = 6 bytes
  lu.assertEquals(#s, 6)

  -- Truncate at 3: inside emoji (bytes 2-5), cut to 1
  lu.assertEquals(util.utf8_truncate(s, 3), 'A')
  -- Truncate at 4: inside emoji (bytes 2-5), cut to 1
  lu.assertEquals(util.utf8_truncate(s, 4), 'A')
  -- Truncate at 5: end of emoji
  lu.assertEquals(util.utf8_truncate(s, 5), 'A😀')
  -- Truncate at 6: full string
  lu.assertEquals(util.utf8_truncate(s, 6), 'A😀B')
end

function TestUtil:testUtf8TruncateAllMultibyte()
  -- All 3-byte characters, truncate in the middle of each
  local s = '你好世界你好世界'
  -- 8 chars * 3 bytes = 24 bytes
  lu.assertEquals(#s, 24)

  -- Cut at 7 (mid 3rd char): should get 2 chars (6 bytes)
  lu.assertEquals(util.utf8_truncate(s, 7), '你好')
  -- Cut at 10 (mid 4th char): should get 3 chars (9 bytes)
  lu.assertEquals(util.utf8_truncate(s, 10), '你好世')
  -- Cut at 1 (mid 1st char): should get empty
  lu.assertEquals(util.utf8_truncate(s, 1), '')
  -- Cut at 2 (mid 1st char): should get empty
  lu.assertEquals(util.utf8_truncate(s, 2), '')
  -- Cut at 3 (end of 1st char): should get 1 char
  lu.assertEquals(util.utf8_truncate(s, 3), '你')
end

return TestUtil

