-- test/icons_spec.lua
-- Coverage for lua/chat/icons.lua: validation, sanitize() and the regex
-- builder used by the result window's message-prefix highlight.
local lu = require('luaunit')
local config = require('chat.config')
local icons = require('chat.icons')
local formatter = require('chat.formatter')

TestIcons = {}

function TestIcons:setUp()
  config.config.icons = vim.deepcopy(config.icon_defaults)
end

function TestIcons:tearDown()
  config.config.icons = vim.deepcopy(config.icon_defaults)
end

function TestIcons:test_valid_single_char()
  lu.assertTrue(icons.is_valid('A'))
  lu.assertTrue(icons.is_valid('>'))
  lu.assertTrue(icons.is_valid('🤖'))
  -- VS16 sequence (U+2764 U+FE0F) is two codepoints but one displayed char
  lu.assertTrue(icons.is_valid('❤️'))
end

function TestIcons:test_valid_disabled_icon()
  -- empty string means "do not draw this icon"
  lu.assertTrue(icons.is_valid(''))
end

function TestIcons:test_invalid_multi_char()
  lu.assertFalse(icons.is_valid('AB'))
  lu.assertFalse(icons.is_valid('🤖👤'))
  lu.assertFalse(icons.is_valid('ab'))
end

function TestIcons:test_invalid_types()
  lu.assertFalse(icons.is_valid(nil))
  lu.assertFalse(icons.is_valid(123))
  lu.assertFalse(icons.is_valid(true))
  lu.assertFalse(icons.is_valid({}))
end

function TestIcons:test_invalid_control_chars()
  lu.assertFalse(icons.is_valid('\n'))
  lu.assertFalse(icons.is_valid('\t'))
end

function TestIcons:test_sanitize_empty_gives_defaults()
  local result = icons.sanitize({})
  lu.assertEquals(result, config.icon_defaults)
end

function TestIcons:test_sanitize_partial_keeps_defaults()
  local result = icons.sanitize({ bot = '>', cache = '' })
  lu.assertEquals(result.bot, '>')
  lu.assertEquals(result.cache, '')
  lu.assertEquals(result.user, config.icon_defaults.user)
  -- the table stays complete, so the deep merge can never leave a hole
  for key in pairs(config.icon_defaults) do
    lu.assertNotNil(result[key])
  end
end

function TestIcons:test_sanitize_invalid_falls_back()
  local result = icons.sanitize({ bot = 'AB', user = 123 })
  lu.assertEquals(result.bot, config.icon_defaults.bot)
  lu.assertEquals(result.user, config.icon_defaults.user)
end

function TestIcons:test_sanitize_unknown_key_ignored()
  local result = icons.sanitize({ nope = 'X' })
  lu.assertNil(result.nope)
  lu.assertEquals(result.bot, config.icon_defaults.bot)
end

function TestIcons:test_sanitize_non_table()
  local result = icons.sanitize('nope')
  lu.assertEquals(result, config.icon_defaults)
end

function TestIcons:test_get_and_padded()
  config.config.icons.bot = '>'
  lu.assertEquals(icons.get('bot'), '>')
  lu.assertEquals(icons.padded('bot'), '> ')

  config.config.icons.bot = ''
  lu.assertEquals(icons.get('bot'), '')
  lu.assertEquals(icons.padded('bot'), '')

  lu.assertEquals(icons.get('unknown'), '')
end

function TestIcons:test_role_pattern_default_icons()
  local pattern = icons.role_pattern()
  lu.assertNotNil(pattern)
  -- an alternation of the four role icons, not a character class
  lu.assertStrContains(pattern, '🤖')
  lu.assertStrContains(pattern, '👤')
  lu.assertStrContains(pattern, '❌')
  lu.assertStrContains(pattern, '🔁')
end

function TestIcons:test_role_pattern_matches_message_prefix()
  local pattern = icons.role_pattern()
  local line = formatter.generate_message({
    role = 'user',
    content = 'hi',
    created = os.time(),
  })[1]
  lu.assertStrContains(vim.fn.matchstr(line, pattern), '👤')
end

function TestIcons:test_role_pattern_escapes_bracket()
  -- `]` would terminate a character class, so it must be escaped
  config.config.icons.bot = ']'
  local pattern = icons.role_pattern()
  lu.assertStrContains(pattern, '\\]')
  lu.assertStrContains(vim.fn.matchstr('[x] ]Bot: hi', pattern), ']')
end

function TestIcons:test_role_pattern_escapes_backslash()
  config.config.icons.notice = '\\'
  local pattern = icons.role_pattern()
  lu.assertTrue(pattern:find('\\\\', 1, true) ~= nil)
end

function TestIcons:test_role_pattern_escapes_magic_chars()
  config.config.icons.error = '^'
  config.config.icons.user = '*'
  local pattern = icons.role_pattern()
  lu.assertStrContains(pattern, '\\^')
  lu.assertStrContains(pattern, '\\*')
end

function TestIcons:test_role_pattern_all_disabled()
  for _, name in ipairs({ 'bot', 'user', 'error', 'notice' }) do
    config.config.icons[name] = ''
  end
  lu.assertNil(icons.role_pattern())
end

function TestIcons:test_formatter_uses_configured_icons()
  config.config.icons.bot = '>'
  config.config.icons.user = '$'
  local bot_lines = formatter.generate_message({
    role = 'assistant',
    content = 'hello',
    created = os.time(),
  })
  lu.assertStrContains(bot_lines[1], '> Bot:')
  local user_lines = formatter.generate_message({
    role = 'user',
    content = 'hi',
    created = os.time(),
  })
  lu.assertStrContains(user_lines[1], '$ You: hi')
end

function TestIcons:test_disabled_icon_leaves_no_gap()
  config.config.icons.user = ''
  local lines = formatter.generate_message({
    role = 'user',
    content = 'hi',
    created = os.time(),
  })
  -- label collapses to 'You:', the line must not start with a double space
  lu.assertStrContains(lines[1], '] You: hi')
  lu.assertNil(lines[1]:find(']  You'))
end

function TestIcons:test_disabled_cache_icon_keeps_single_space()
  config.config.icons.cache = ''
  local lines = formatter.generate_message({
    on_complete = true,
    usage = {
      total_tokens = 1000,
      prompt_tokens = 1000,
      completion_tokens = 0,
      prompt_cache_hit_tokens = 400,
    },
    created = os.time(),
  })
  lu.assertStrContains(lines[1], ' 40%')
  lu.assertNil(lines[1]:find('  40%'))
end

function TestIcons:test_setup_validates_icons()
  config.setup({ icons = { cache = 'C', bot = 'AB' } })
  lu.assertEquals(config.config.icons.cache, 'C')
  lu.assertEquals(config.config.icons.bot, config.icon_defaults.bot)
  lu.assertEquals(config.config.icons.user, config.icon_defaults.user)
end

return TestIcons

