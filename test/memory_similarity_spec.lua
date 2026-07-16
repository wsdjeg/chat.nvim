-- test/memory_similarity_spec.lua
local lu = require('luaunit')
local similarity = require('chat.memory.similarity')

TestMemorySimilarity = {}

-- === text_similarity ===

function TestMemorySimilarity:testNilInputs()
  lu.assertEquals(similarity.text_similarity(nil, 'hello'), 0)
  lu.assertEquals(similarity.text_similarity('hello', nil), 0)
  lu.assertEquals(similarity.text_similarity(nil, nil), 0)
end

function TestMemorySimilarity:testExactMatch()
  lu.assertEquals(similarity.text_similarity('hello', 'hello'), 1.0)
  lu.assertEquals(similarity.text_similarity('Hello', 'hello'), 1.0)
  lu.assertEquals(similarity.text_similarity('HELLO', 'hello'), 1.0)
end

function TestMemorySimilarity:testSubstringMatch()
  local score = similarity.text_similarity('vim', 'I love vim editor')
  lu.assertEquals(score, 0.8)
end

function TestMemorySimilarity:testTokenOverlapEnglish()
  local score = similarity.text_similarity('neovim plugin', 'neovim lua plugin')
  -- Both tokens match: 2/2 = 1.0
  lu.assertEquals(score, 1.0)
end

function TestMemorySimilarity:testTokenOverlapPartial()
  local score = similarity.text_similarity('neovim python', 'neovim lua plugin')
  -- 1 out of 2 tokens match
  lu.assertTrue(score >= 0.5)
  lu.assertTrue(score < 1.0)
end

function TestMemorySimilarity:testNoTokenOverlap()
  local score = similarity.text_similarity('apple', 'zebra')
  -- Should fall back to levenshtein, which is low for completely different words
  lu.assertTrue(score < 0.3)
end

function TestMemorySimilarity:testChineseBigramMatch()
  local score = similarity.text_similarity('编辑器', '我喜欢编辑器')
  -- Should get substring match 0.8 since '编辑器' is in content
  lu.assertEquals(score, 0.8)
end

function TestMemorySimilarity:testChineseTokenOverlap()
  local score = similarity.text_similarity('编辑器 配置', '编辑器 配置 插件')
  -- Should match tokens well
  lu.assertTrue(score >= 0.5)
end

function TestMemorySimilarity:testEmptyStrings()
  lu.assertEquals(similarity.text_similarity('', ''), 1.0)
  lu.assertEquals(similarity.text_similarity('hello', ''), 0)
end

-- === Levenshtein fallback ===

function TestMemorySimilarity:testFuzzyMatch()
  -- "hello" vs "hallo" - one char difference
  local score = similarity.text_similarity('hello', 'hallo')
  lu.assertTrue(score > 0)
  -- Should be reasonable but not perfect
  lu.assertTrue(score < 1.0)
end

function TestMemorySimilarity:testFuzzyMatchCloseTypo()
  -- "neovim" vs "neovin" - very close, one char diff
  -- Levenshtein: 1/6 = 0.833, scaled by 0.6 = 0.5
  local score = similarity.text_similarity('neovim', 'neovin')
  lu.assertTrue(score >= 0.5)
end

function TestMemorySimilarity:testCompletelyDifferent()
  local score = similarity.text_similarity('abc', 'xyz')
  lu.assertTrue(score < 0.2)
end

-- === find_best_match ===

function TestMemorySimilarity:testFindBestMatch()
  local contents = {
    { content = 'I love neovim' },
    { content = 'Python is great' },
    { content = 'neovim plugin development' },
  }

  local best, score = similarity.find_best_match('neovim', contents, 0.3)
  lu.assertNotNil(best)
  lu.assertTrue(score >= 0.3)
  -- Should match one of the neovim entries
  lu.assertNotNil(best.content:find('neovim'))
end

function TestMemorySimilarity:testFindBestMatchNoMatch()
  local contents = {
    { content = 'apple' },
    { content = 'banana' },
  }

  local best, score = similarity.find_best_match('zebra', contents, 0.5)
  lu.assertNil(best)
  lu.assertNil(score)
end

function TestMemorySimilarity:testFindBestMatchStringEntries()
  local contents = { 'hello world', 'neovim lua' }

  local best = similarity.find_best_match('neovim', contents, 0.3)
  lu.assertNotNil(best)
end

-- === Integration: modules use shared similarity ===

function TestMemorySimilarity:testLongTermUsesSharedSimilarity()
  local long_term = require('chat.memory.long_term')
  -- The module should have text_similarity that delegates to shared module
  lu.assertNotNil(long_term.text_similarity)
  lu.assertEquals(long_term.text_similarity('hello', 'hello'), 1.0)
  lu.assertEquals(long_term.text_similarity('vim', 'I use vim'), 0.8)
end

function TestMemorySimilarity:testDailyUsesSharedSimilarity()
  local daily = require('chat.memory.daily')
  -- The module should have text_similarity that delegates to shared module
  lu.assertNotNil(daily.text_similarity)
  lu.assertEquals(daily.text_similarity('hello', 'hello'), 1.0)
  lu.assertEquals(daily.text_similarity('vim', 'I use vim'), 0.8)
  -- Previously daily returned 0.4 for non-exact/non-substring; now it should use real similarity
  local score = daily.text_similarity('neovim lua', 'neovim plugin lua')
  lu.assertTrue(score > 0.4, 'daily should use real similarity, not hardcoded 0.4')
end

function TestMemorySimilarity:testWorkingUsesSharedSimilarity()
  local working = require('chat.memory.working')
  -- The module should have text_similarity that delegates to shared module
  lu.assertNotNil(working.text_similarity)
  lu.assertEquals(working.text_similarity('hello', 'hello'), 1.0)
  lu.assertEquals(working.text_similarity('vim', 'I use vim'), 0.8)
end

return TestMemorySimilarity

