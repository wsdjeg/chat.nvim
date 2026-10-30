-- luaunit tests for chat.usage (normalized token usage)
local lu = require('luaunit')

local usage = require('chat.usage')

TestUsage = {}

function TestUsage:test_normalize_nil()
  local u = usage.normalize(nil)
  lu.assertEquals(u.total_tokens, 0)
  lu.assertEquals(u.prompt_tokens, 0)
  lu.assertEquals(u.completion_tokens, 0)
  lu.assertEquals(u.cached_tokens, 0)
end

function TestUsage:test_normalize_openai_details()
  local u = usage.normalize({
    prompt_tokens = 1000,
    completion_tokens = 200,
    total_tokens = 1200,
    prompt_tokens_details = { cached_tokens = 800 },
  })
  lu.assertEquals(u.total_tokens, 1200)
  lu.assertEquals(u.cached_tokens, 800)
  lu.assertEquals(usage.hit_ratio(u), 0.8)
end

function TestUsage:test_cached_tokens_deepseek()
  local raw = { prompt_tokens = 1000, prompt_cache_hit_tokens = 500 }
  lu.assertEquals(usage.cached_tokens(raw), 500)
  lu.assertEquals(usage.hit_ratio(raw), 0.5)
end

function TestUsage:test_cached_tokens_anthropic()
  local raw = {
    input_tokens = 900,
    prompt_tokens = 1000,
    cache_read_input_tokens = 250,
    cache_creation_input_tokens = 100,
  }
  lu.assertEquals(usage.cached_tokens(raw), 250)
  lu.assertEquals(usage.hit_ratio(raw), 0.25)
end

function TestUsage:test_cached_tokens_plain()
  lu.assertEquals(usage.cached_tokens({ prompt_tokens = 10 }), 0)
  lu.assertEquals(usage.cached_tokens('nonsense'), 0)
  lu.assertEquals(usage.hit_ratio({ prompt_tokens = 0 }), 0)
end

function TestUsage:test_total_falls_back_to_prompt_plus_completion()
  local u = usage.normalize({ prompt_tokens = 30, completion_tokens = 12 })
  lu.assertEquals(u.total_tokens, 42)
end

function TestUsage:test_hit_ratio_clamped()
  local raw = { prompt_tokens = 100, cached_tokens = 400 }
  lu.assertEquals(usage.hit_ratio(raw), 1)
end

function TestUsage:test_add_and_sum()
  local messages = {
    { role = 'assistant', usage = { prompt_tokens = 100, completion_tokens = 10 } },
    { role = 'tool' },
    {
      role = 'assistant',
      usage = {
        prompt_tokens = 200,
        completion_tokens = 20,
        total_tokens = 220,
        prompt_cache_hit_tokens = 50,
      },
    },
  }

  local total = usage.sum(messages)
  lu.assertEquals(total.total_tokens, 330)
  lu.assertEquals(total.prompt_tokens, 300)
  lu.assertEquals(total.completion_tokens, 30)
  lu.assertEquals(total.cached_tokens, 50)

  -- add() mutates and returns the accumulator
  local acc = usage.add({ total_tokens = 1 }, { prompt_tokens = 1 })
  lu.assertEquals(acc.total_tokens, 2)
end

function TestUsage:test_sum_handles_garbage()
  lu.assertEquals(usage.sum(nil).total_tokens, 0)
  lu.assertEquals(usage.sum({ 'x', 42 }).total_tokens, 0)
end

function TestUsage:test_summary()
  lu.assertEquals(usage.summary(nil), '0 tokens')

  lu.assertEquals(
    usage.summary({ total_tokens = 12345, prompt_tokens = 12000 }),
    '12.3K tokens'
  )

  -- cache suffix appears for every provider shape
  lu.assertEquals(
    usage.summary({
      prompt_tokens = 1000,
      completion_tokens = 0,
      prompt_cache_hit_tokens = 450,
    }),
    '1.0K tokens · 45% cached'
  )
end

return TestUsage

