-- Multi-token support: multiple api keys per provider with round-robin
-- rotation and per-key cooldown on rate-limit / server errors.
--
-- Configuration (backward compatible):
--   api_key = {
--     deepseek = 'sk-...',                 -- single key (old behavior)
--     volcengine_coding_plan = {           -- multiple keys: rotated
--       'uuid-of-account-1',
--       'uuid-of-account-2',
--     },
--   }
--
-- Rotation is per provider and shared across sessions. A key whose request
-- fails with a rate limit (429) or server error (5xx) is put on cooldown
-- for `token_cooldown` seconds (default 30) and skipped until it expires.
-- Network errors (connection refused, timeouts, ...) do NOT cool a key
-- down; those are handled by the retry module instead.
local M = {}

local config = require('chat.config')
local log = require('chat.log')

-- provider -> { index = number (1-based cursor), cooldown = { [key_index] = ms } }
local state = {}

-- jobid -> { provider = string, key_index = number }
-- Associates a streaming request with the api key it was sent with, so
-- protocol error handlers can cool down exactly that key.
local jobs = {}

-- Injectable monotonic clock (milliseconds) for tests.
M._clock = function()
  return vim.uv.now()
end

--- Normalize the api_key config for a provider into a list of keys.
--- A single string becomes a one-element list (backward compatible);
--- arrays are filtered for empty / non-string entries.
--- @param provider string Provider name (field of config.api_key)
--- @return string[]|nil Key list, nil when the provider has no usable key
function M.normalize(provider)
  local api_key = config.config.api_key
  local key = api_key and api_key[provider] or nil
  if type(key) == 'string' then
    if key == '' then
      return nil
    end
    return { key }
  elseif type(key) == 'table' then
    local keys = {}
    for _, v in ipairs(key) do
      if type(v) == 'string' and v ~= '' then
        table.insert(keys, v)
      end
    end
    return keys
  end
  return nil
end

--- Get the key at `index` (1-based, wraps around).
--- @param provider string Provider name
--- @param index integer 1-based key index
--- @return string|nil
function M.get_token(provider, index)
  local keys = M.normalize(provider)
  if not keys or #keys == 0 or index < 1 then
    return nil
  end
  return keys[((index - 1) % #keys) + 1]
end

local function ensure_state(provider)
  local s = state[provider]
  if not s then
    s = { index = 1, cooldown = {} }
    state[provider] = s
  end
  return s
end

local function cooldown_ms()
  local seconds = config.config.token_cooldown
  if type(seconds) ~= 'number' or seconds < 0 then
    seconds = 30
  end
  return seconds * 1000
end

--- Return the next usable api key and its 1-based index.
--- Round-robins across keys, skipping keys in cooldown. When every key is
--- cooling down, falls back to the key whose cooldown expires soonest, so
--- the request is still attempted (the API error stays visible to the
--- user instead of failing silently).
--- @param provider string Provider name
--- @return string|nil key
--- @return integer|nil key_index
function M.next(provider)
  local keys = M.normalize(provider)
  if not keys or #keys == 0 then
    return nil, nil
  end

  local s = ensure_state(provider)
  -- Keep the cursor in range (fail() may have pushed it past the end)
  s.index = ((s.index - 1) % #keys) + 1

  local clock = M._clock()
  local fallback_index, fallback_until = nil, math.huge

  for _ = 1, #keys do
    local i = s.index
    local until_t = s.cooldown[i] or 0
    if clock >= until_t then
      -- Advance the cursor so the next call rotates to the following key
      s.index = (i % #keys) + 1
      return keys[i], i
    end
    if until_t < fallback_until then
      fallback_index, fallback_until = i, until_t
    end
    s.index = (i % #keys) + 1
  end

  -- All keys are cooling down: try the one that recovers first
  log.warn(string.format(
    'chat.nvim: all %d api keys for %s are cooling down, retrying key #%d',
    #keys,
    provider,
    fallback_index
  ))
  s.index = (fallback_index % #keys) + 1
  return keys[fallback_index], fallback_index
end

--- Mark a key as failed: put it on cooldown and move the cursor to the
--- next key.
--- @param provider string Provider name
--- @param key_index integer 1-based index of the failed key
function M.fail(provider, key_index)
  local keys = M.normalize(provider)
  if not keys or #keys == 0 or key_index < 1 then
    return
  end
  local s = ensure_state(provider)
  local cd = cooldown_ms()
  s.cooldown[key_index] = M._clock() + cd
  s.index = (key_index % #keys) + 1
  log.warn(string.format(
    'chat.nvim: api key #%d for %s hit a rate limit / server error, cooling down for %gs',
    key_index,
    provider,
    cd / 1000
  ))
end

--- Reset rotation state for one provider, or for all providers when
--- `provider` is nil.
--- @param provider? string Provider name
function M.reset(provider)
  if provider then
    state[provider] = nil
  else
    state = {}
  end
end

--- Associate a job with the api key it was started with.
--- Called by providers right after job.start(); the protocol error
--- handlers later use the binding to cool down exactly this key.
--- @param jobid integer The job id returned by job.start()
--- @param provider string Provider name
--- @param key_index integer 1-based index of the key used
function M.bind(jobid, provider, key_index)
  if jobid and jobid > 0 then
    jobs[jobid] = { provider = provider, key_index = key_index }
  end
end

--- Drop the job -> key association (called when the job exits).
--- @param jobid integer
function M.unbind(jobid)
  jobs[jobid] = nil
end

-- Error signals that justify switching to another api key: per-key limits
-- (429 / rate limit / quota) and server errors (5xx). Normal completions
-- (max_tokens truncation, content filter) are NOT token errors and must
-- never cool a key down.
local TOKEN_ERROR_PATTERNS = {
  'rate[%-_%s]?limit', -- "rate limit", "rate_limit", "RateLimitError"
  'too many requests',
  'throttl', -- "throttle", "throttling", "Throttling.RateQuota"
  'quota', -- "QuotaExceeded", "check quota"
  'exhausted', -- Gemini "RESOURCE_EXHAUSTED"
  'server[%-_%s]?error', -- "server_error", "internal server error"
  'internal server',
  'bad gateway',
  'gateway timeout',
  'service unavailable',
  'unavailable', -- Gemini "UNAVAILABLE"
  'overloaded', -- Anthropic "overloaded_error" (529)
}

--- Check whether an API error code / message looks like a rate limit or a
--- server error, i.e. worth rotating the api key.
--- @param code number|string|nil Error code from the API response
--- @param msg string|nil Error message from the API response
--- @return boolean
function M.is_token_error(code, msg)
  if code ~= nil then
    -- tonumber() errors on userdata (vim.NIL), tostring() first
    local n = tonumber(tostring(code))
    if n and (n == 429 or (n >= 500 and n <= 599)) then
      return true
    end
  end
  local text = string.format('%s %s', tostring(code or ''), tostring(msg or '')):lower()
  for _, pattern in ipairs(TOKEN_ERROR_PATTERNS) do
    if text:find(pattern) then
      return true
    end
  end
  return false
end

--- Report an API error for a finished job: cool the key down when the
--- error looks like a rate limit / server error. Safe to call from
--- protocol error handlers; jobs without a key binding are ignored.
--- @param jobid integer The job id
--- @param code number|string|nil Error code from the API response
--- @param msg string|nil Error message from the API response
function M.report_error(jobid, code, msg)
  local binding = jobs[jobid]
  if not binding then
    return
  end
  if not M.is_token_error(code, msg) then
    return
  end
  -- Clear the binding first: a duplicated error event for the same job
  -- (stream chunk + buffered body) must not cool the key down twice.
  jobs[jobid] = nil
  M.fail(binding.provider, binding.key_index)
end

return M

