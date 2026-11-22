-- test/windows/complete_spec.lua
-- Skill completion for the prompt window (CTRL-X CTRL-U).
--
-- The tests drive `complete.context` / `complete.items` / `complete.arg_items`
-- directly, so they do not depend on insert-mode key sequences. The
-- 'completefunc' entry point is covered through an explicit opt check plus
-- end-to-end calls: one to the Lua entry point, and one through the global
-- Vimscript wrapper that the option actually points at.

local lu = require('luaunit')
local config = require('chat.config')
local skills = require('chat.skills')
local complete = require('chat.windows.complete')
local prompt = require('chat.windows.prompt')

TestWindowsComplete = {}

function TestWindowsComplete:setUp()
  config.setup({
    provider = 'test-provider',
    model = 'test-model',
    storage_dir = vim.fn.tempname(),
  })
  for _, s in ipairs(skills.list()) do
    skills.unregister(s.name)
  end
  skills.init()

  skills.register({
    name = 'greet',
    description = 'Say hello to someone nice',
    handler = function() end,
  })
  skills.register({
    name = 'model-select',
    description = 'Long description used to verify the truncation of the menu',
    handler = function() end,
    complete = function()
      return { 'gpt-4o', 'gpt-4o-mini', 'claude-3' }
    end,
  })
end

function TestWindowsComplete:tearDown()
  for _, s in ipairs(skills.list()) do
    skills.unregister(s.name)
  end
  skills.init()
end

--- Collect the `word` field of every candidate.
--- @param items table[] 'completefunc' items
--- @return string[]
local function words_of(items)
  local words = {}
  for _, item in ipairs(items) do
    table.insert(words, item.word)
  end
  return words
end

--- Open the prompt buffer in a window and put `line` in it with the cursor at
--- byte column `col` (0-based).
--- @param line string
--- @param col integer
--- @return integer buf, integer win
local function edit_prompt(line, col)
  local buf = prompt.create_buffer()
  local win = prompt.open_window(buf, 0, 0, 40, 'sess')
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { line })
  vim.api.nvim_win_set_cursor(win, { 1, col })
  return buf, win
end

-- Context detection ---------------------------------------------------------

function TestWindowsComplete:testContextSkillName()
  local ctx = complete.context('/cle', 4)
  lu.assertNotNil(ctx)
  lu.assertEquals('name', ctx.kind)
  lu.assertEquals(0, ctx.start)
  lu.assertEquals('/cle', ctx.base)
end

function TestWindowsComplete:testContextSkillNameAfterWhitespace()
  local line = '  /mo'
  local ctx = complete.context(line, #line)
  lu.assertNotNil(ctx)
  lu.assertEquals('name', ctx.kind)
  lu.assertEquals(2, ctx.start)
  lu.assertEquals('/mo', ctx.base)
end

function TestWindowsComplete:testContextBareSlash()
  local ctx = complete.context('/', 1)
  lu.assertNotNil(ctx)
  lu.assertEquals('name', ctx.kind)
  lu.assertEquals('/', ctx.base)
end

function TestWindowsComplete:testContextPlainWordIsCancelled()
  lu.assertNil(complete.context('hello wor', 9))
end

function TestWindowsComplete:testContextAbsolutePathIsNotASkill()
  -- A token that merely contains a slash mid-way is not a skill name.
  lu.assertNil(complete.context('/tmp/foo', 8))
end

function TestWindowsComplete:testContextArgsOfSkillWithComplete()
  local line = '/model-select gp'
  local ctx = complete.context(line, #line)
  lu.assertNotNil(ctx)
  lu.assertEquals('args', ctx.kind)
  lu.assertEquals('gp', ctx.base)
  lu.assertEquals(14, ctx.start)
  lu.assertEquals('model-select', ctx.skill.name)
end

function TestWindowsComplete:testContextArgsOfSkillWithoutComplete()
  local line = '/greet No'
  lu.assertNil(complete.context(line, #line))
end

function TestWindowsComplete:testContextArgsOfUnknownSkill()
  local line = '/nope gp'
  lu.assertNil(complete.context(line, #line))
end

function TestWindowsComplete:testContextTrailingSpaceStillCompletes()
  local line = '/model-select '
  local ctx = complete.context(line, #line)
  lu.assertNotNil(ctx)
  lu.assertEquals('args', ctx.kind)
  lu.assertEquals('', ctx.base)
end

-- Candidate lists -----------------------------------------------------------

function TestWindowsComplete:testItemsFiltersByPrefix()
  local words = words_of(complete.items('/gr'))
  lu.assertEquals(1, #words)
  lu.assertEquals('/greet', words[1])
end

function TestWindowsComplete:testItemsWordKeepsLeadingSlash()
  -- 'completefunc' replaces text from the start column, which points at "/".
  for _, item in ipairs(complete.items('/gre')) do
    lu.assertEquals('/', item.word:sub(1, 1))
  end
end

function TestWindowsComplete:testItemsIncludeDescription()
  local items = complete.items('/greet')
  lu.assertEquals(1, #items)
  lu.assertEquals('/greet', items[1].word)
  lu.assertEquals('Say hello to someone nice', items[1].menu)
  lu.assertEquals('Say hello to someone nice', items[1].info)
end

function TestWindowsComplete:testItemsEmptyPrefixListsEverything()
  local items = complete.items('')
  lu.assertTrue(#items >= 2)
end

function TestWindowsComplete:testItemsMatchingIsCaseInsensitive()
  local words = words_of(complete.items('/GR'))
  lu.assertEquals(1, #words)
  lu.assertEquals('/greet', words[1])
end

function TestWindowsComplete:testItemsNoMatch()
  lu.assertEquals(0, #complete.items('/zzzz'))
end

function TestWindowsComplete:testArgItemsDelegatesToSkillComplete()
  local line = '/model-select gpt'
  local ctx = complete.context(line, #line)
  local words = words_of(complete.arg_items(ctx, 'gpt'))
  lu.assertEquals(2, #words)
  lu.assertEquals('gpt-4o', words[1])
  lu.assertEquals('gpt-4o-mini', words[2])
end

function TestWindowsComplete:testArgItemsSurvivesHandlerError()
  skills.register({
    name = 'boom',
    description = 'complete throws',
    handler = function() end,
    complete = function()
      error('nope')
    end,
  })
  local ctx = complete.context('/boom ar', #'/boom ar')
  lu.assertNotNil(ctx)
  lu.assertEquals(0, #complete.arg_items(ctx, 'ar'))
end

function TestWindowsComplete:testArgItemsIgnoresNonStringEntries()
  skills.register({
    name = 'mixed',
    description = '',
    handler = function() end,
    complete = function()
      return { 'good', nil, 42, '' }
    end,
  })
  local ctx = complete.context('/mixed ', #'/mixed ')
  local words = words_of(complete.arg_items(ctx, ''))
  lu.assertEquals(1, #words)
  lu.assertEquals('good', words[1])
end

-- Truncation ----------------------------------------------------------------

function TestWindowsComplete:testTruncateCollapsesNewlines()
  lu.assertEquals('a b', complete.truncate('a\nb'))
end

function TestWindowsComplete:testTruncateKeepsShortText()
  lu.assertEquals('short', complete.truncate('short', 10))
end

function TestWindowsComplete:testTruncateCutsLongText()
  local text = complete.truncate(string.rep('x', 60), 10)
  -- width characters including the ellipsis that replaces the last one
  lu.assertEquals(10, vim.fn.strchars(text))
  lu.assertEquals('…', vim.fn.strcharpart(text, 9, 1))
end

function TestWindowsComplete:testItemsTruncateLongDescription()
  local items = complete.items('/model-select')
  lu.assertEquals(1, #items)
  lu.assertTrue(vim.fn.strchars(items[1].menu) <= complete.MENU_WIDTH)
end

-- completefunc entry point --------------------------------------------------

function TestWindowsComplete:testCompletefuncFindstartOnSkillName()
  edit_prompt('/gr', 3)

  lu.assertEquals(0, complete.completefunc(1, ''))
  local items = complete.completefunc(0, '/gr')
  lu.assertEquals(1, #items)
  lu.assertEquals('/greet', items[1].word)
end

function TestWindowsComplete:testCompletefuncCancelsOutsideSkill()
  edit_prompt('hello world', 11)

  lu.assertEquals(-3, complete.completefunc(1, ''))
  lu.assertEquals(0, #complete.completefunc(0, 'world'))
end

function TestWindowsComplete:testPromptBufferSetsCompletefunc()
  local buf = prompt.create_buffer()
  local value = vim.api.nvim_get_option_value('completefunc', { buf = buf })
  lu.assertEquals(complete.option_value(), value)
end

function TestWindowsComplete:testOptionValueIsADefinedFunction()
  -- The option is evaluated as an expression, so the name must be callable.
  -- A bare `v:lua.<global>` is rejected as an invalid expression on recent
  -- Neovim releases, which is why the option names a Vimscript wrapper.
  local name = complete.option_value()
  lu.assertNotStrContains(name, 'v:lua.')
  lu.assertEquals(1, vim.fn.exists('*' .. name))
end

function TestWindowsComplete:testVimWrapperCompletesSkillName()
  edit_prompt('/gr', 3)
  local name = complete.option_value()

  lu.assertEquals(0, vim.fn[name](1, ''))

  -- Through Vimscript each candidate arrives as a dict, not a bare string.
  local items = vim.fn[name](0, '/gr')
  lu.assertEquals(1, #items)
  lu.assertEquals('/greet', items[1].word)
  lu.assertEquals('Say hello to someone nice', items[1].menu)
end

function TestWindowsComplete:testVimWrapperCancelsOutsideSkill()
  edit_prompt('hello world', 11)
  local name = complete.option_value()

  lu.assertEquals(-3, vim.fn[name](1, ''))
  lu.assertEquals(0, #vim.fn[name](0, 'world'))
end

return TestWindowsComplete

