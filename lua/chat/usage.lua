-- lua/chat/usage.lua
-- Normalized token usage.
--
-- Every provider reports usage with its own shape, so the UI kept
-- re-implementing "which field holds the cached tokens" in several places and
-- got it wrong in most of them (only the OpenAI `prompt_tokens_details` shape
-- was understood, so DeepSeek and Anthropic cache hits always displayed 0%).
--
-- This module is the single source of truth:
--   * normalize(usage)      one flat record: total/prompt/completion/cached
--   * cached_tokens(usage)  provider-specific cache field -> number
--   * hit_ratio(usage)      cached / prompt in 0..1
--   * summary(usage)        one-line label for the UI
--   * sum(messages) / add() accumulate over messages or across turns
--
-- Cache field per provider:
--   openai / dashscope  usage.prompt_tokens_details.cached_tokens
--   deepseek            usage.prompt_cache_hit_tokens
--   anthropic           usage.cache_read_input_tokens
--   generic             usage.cached_tokens

local M = {}

local util = require('chat.util')

--- A safe non-negative number from a provider payload.
--- @param v any
--- @return number
local function num(v)
  if type(v) ~= 'number' or v ~= v or v < 0 then
    return 0
  end
  return v
end

--- Zeroed totals record.
--- @return table
function M.empty()
  return {
    total_tokens = 0,
    prompt_tokens = 0,
    completion_tokens = 0,
    cached_tokens = 0,
  }
end

--- Prompt tokens that were served from the provider prefix cache.
--- Missing or unrecognised shapes yield 0 (never nil), so callers can do
--- arithmetic without guards.
--- @param usage table|nil
--- @return integer
function M.cached_tokens(usage)
  if type(usage) ~= 'table' then
    return 0
  end

  local n = num(usage.cached_tokens)
  if n > 0 then
    return n
  end

  -- deepseek
  n = num(usage.prompt_cache_hit_tokens)
  if n > 0 then
    return n
  end

  -- anthropic
  n = num(usage.cache_read_input_tokens)
  if n > 0 then
    return n
  end

  -- openai / dashscope
  local details = usage.prompt_tokens_details
  if type(details) == 'table' then
    n = num(details.cached_tokens)
  end
  return n
end

--- Normalize one provider usage payload.
--- total_tokens falls back to prompt + completion when the provider omits it.
--- @param usage table|nil
--- @return table { total_tokens, prompt_tokens, completion_tokens, cached_tokens }
function M.normalize(usage)
  local u = M.empty()
  if type(usage) ~= 'table' then
    return u
  end

  u.prompt_tokens = num(usage.prompt_tokens)
  u.completion_tokens = num(usage.completion_tokens)
  u.total_tokens = num(usage.total_tokens)
  u.cached_tokens = M.cached_tokens(usage)
  if u.total_tokens <= 0 then
    u.total_tokens = u.prompt_tokens + u.completion_tokens
  end
  return u
end

--- Fraction of the prompt served from cache, 0..1.
--- Providers that report no cache numbers get 0, not nil.
--- @param usage table|nil
--- @return number
function M.hit_ratio(usage)
  local u = M.normalize(usage)
  if u.prompt_tokens <= 0 then
    return 0
  end
  local r = u.cached_tokens / u.prompt_tokens
  if r > 1 then
    return 1
  end
  return r
end

--- Accumulate one usage payload into an existing totals record.
--- Mutates and returns acc so callers can chain.
--- @param acc table|nil totals record (see M.empty)
--- @param usage table|nil provider usage payload
--- @return table
function M.add(acc, usage)
  local total = acc or M.empty()
  local u = M.normalize(usage)
  total.total_tokens = num(total.total_tokens) + u.total_tokens
  total.prompt_tokens = num(total.prompt_tokens) + u.prompt_tokens
  total.completion_tokens = num(total.completion_tokens) + u.completion_tokens
  total.cached_tokens = num(total.cached_tokens) + u.cached_tokens
  return total
end

--- Sum usage over a message list ({ { usage = ... }, ... }).
--- @param messages table|nil
--- @return table totals record
function M.sum(messages)
  local total = M.empty()
  if type(messages) ~= 'table' then
    return total
  end
  for _, m in ipairs(messages) do
    if type(m) == 'table' then
      M.add(total, m.usage)
    end
  end
  return total
end

--- One-line usage label: "12.3K tokens · 45% cached".
--- The cache part is omitted when the provider reports nothing, so the label
--- degrades to "12.3K tokens".
--- @param usage table|nil provider usage payload or totals record
--- @return string
function M.summary(usage)
  local u = M.normalize(usage)
  if u.total_tokens <= 0 then
    return '0 tokens'
  end

  local parts = { util.format_number(u.total_tokens) .. ' tokens' }
  if u.cached_tokens > 0 then
    parts[#parts + 1] = string.format(
      '%d%% cached',
      math.floor(M.hit_ratio(usage) * 100 + 0.5)
    )
  end
  return table.concat(parts, ' · ')
end

return M

