-- lua/chat/usage_stats.lua
-- Per provider/model request and token accounting.
--
-- Every finished request is counted exactly once: sessions.on_complete
-- (the funnel that also writes the usage footer message) calls record()
-- with the session's provider/model and the final usage payload. Tool-call
-- rounds and auto-continuation chains each get their own on_complete, so
-- the "requests" counter matches real HTTP requests.
--
-- Storage: {storage_dir}/usage_stats.json, three layers with identical
-- record shapes ([provider][model] = { requests, total_tokens,
-- prompt_tokens, completion_tokens, cached_tokens }):
--   total   lifetime totals, never vacuumed
--   hourly  buckets keyed "YYYY-MM-DDTHH" (fixed-width ISO keys, so
--           lexicographic order == chronological order), retained
--           usage_stats.hourly_days (default 7 days)
--   daily   buckets keyed "YYYY-MM-DD", retained usage_stats.daily_days
--           (default 365 days)
--
-- Queries:
--   total()        all-time [provider][model] totals
--   range(since)   window query; spans < 48h merge hourly buckets,
--                  longer spans merge daily buckets. The bucket holding
--                  the window start is included whole, so a window can
--                  overshoot by at most one bucket.
--   reset()        clear all three layers
--
-- Token payloads are normalized through chat.usage, so provider-specific
-- cache fields (prompt_tokens_details.cached_tokens,
-- cache_read_input_tokens, prompt_cache_hit_tokens) accumulate
-- identically regardless of provider. A missing or corrupt stats file
-- degrades to zeroed layers and is rewritten on the next record().

local M = {}

local config = require('chat.config')
local usage = require('chat.usage')
local atomic = require('chat.memory.atomic')

local DEFAULT_MODEL_KEY = '(default)'
local UNKNOWN_PROVIDER_KEY = 'unknown'

local function stats_path()
  return config.config.storage_dir .. 'usage_stats.json'
end

--- A '/' in a model name (openrouter: "anthropic/claude-sonnet-4")
--- would look like a path separator if stats were ever split into
--- per-provider files; store ':' instead.
--- @param s string
--- @return string
local function sanitize_key(s)
  return (s:gsub('/', ':'))
end

--- @param provider string|nil
--- @return string
local function provider_key(provider)
  if type(provider) ~= 'string' or provider == '' then
    return UNKNOWN_PROVIDER_KEY
  end
  return sanitize_key(provider)
end

--- @param model string|nil
--- @return string
local function model_key(model)
  if type(model) ~= 'string' or model == '' then
    return DEFAULT_MODEL_KEY
  end
  return sanitize_key(model)
end

--- Retention config with defaults, clamped to non-negative.
--- @return number, number hourly_days, daily_days
local function retention()
  local conf = config.config.usage_stats or {}
  local hourly = tonumber(conf.hourly_days) or 7
  local daily = tonumber(conf.daily_days) or 365
  if hourly < 0 then
    hourly = 0
  end
  if daily < 0 then
    daily = 0
  end
  return hourly, daily
end

--- Load the stats file. Missing or corrupt file yields a zeroed
--- three-layer structure, never nil and never an error.
--- @return table { total, hourly, daily }
function M.load()
  local zero = { total = {}, hourly = {}, daily = {} }
  local file = io.open(stats_path(), 'r')
  if not file then
    return zero
  end
  local content = file:read('*a')
  file:close()
  local ok, data = pcall(vim.json.decode, content)
  if not ok or type(data) ~= 'table' then
    return zero
  end
  return {
    total = type(data.total) == 'table' and data.total or {},
    hourly = type(data.hourly) == 'table' and data.hourly or {},
    daily = type(data.daily) == 'table' and data.daily or {},
  }
end

--- Persist the stats file atomically (see chat.memory.atomic).
--- Creates the storage directory when missing.
--- @param stats table { total, hourly, daily }
--- @return boolean
function M.save(stats)
  local dir = config.config.storage_dir
  if vim.fn.isdirectory(dir) == 0 then
    local ok = pcall(vim.fn.mkdir, dir, 'p')
    if not ok then
      return false
    end
  end
  return atomic.atomic_write(stats_path(), vim.json.encode(stats))
end

--- Add one request's usage into a [provider][model] layer.
--- Mutates the layer; returns the updated record.
--- @param layer table [provider][model] = record
--- @param p string provider key
--- @param m string model key
--- @param u table|nil usage payload (any provider shape)
--- @return table
local function bump(layer, p, m, u)
  layer[p] = layer[p] or {}
  local rec = layer[p][m]
  if type(rec) ~= 'table' then
    rec = { requests = 0 }
  end
  rec.requests = (tonumber(rec.requests) or 0) + 1
  usage.add(rec, u)
  layer[p][m] = rec
  return rec
end

--- Drop buckets older than their retention windows. Bucket keys are
--- fixed-width ISO strings, so lexicographic comparison is
--- chronological. Lazy: called from record(), so an idle installation
--- keeps its last buckets on disk until the next request.
--- @param stats table { total, hourly, daily }
--- @param now? number unix timestamp (defaults to os.time())
function M.vacuum(stats, now)
  now = now or os.time()
  local hourly_days, daily_days = retention()
  local cutoff_h = os.date('%Y-%m-%dT%H', now - hourly_days * 86400)
  local cutoff_d = os.date('%Y-%m-%d', now - daily_days * 86400)
  for key in pairs(stats.hourly or {}) do
    if key < cutoff_h then
      stats.hourly[key] = nil
    end
  end
  for key in pairs(stats.daily or {}) do
    if key < cutoff_d then
      stats.daily[key] = nil
    end
  end
end

--- Record one finished request into all three layers.
--- No-op when usage_stats.enable = false. Never raises: a broken stats
--- file degrades to zeroed layers and is rewritten on save.
--- @param provider string|nil session provider name
--- @param model string|nil session model name
--- @param u table|nil final usage payload of the request
function M.record(provider, model, u)
  local conf = config.config.usage_stats
  if type(conf) == 'table' and conf.enable == false then
    return
  end

  local stats = M.load()
  local p = provider_key(provider)
  local m = model_key(model)
  local now = os.time()

  bump(stats.total, p, m, u)

  local hour_key = os.date('%Y-%m-%dT%H', now)
  stats.hourly[hour_key] = stats.hourly[hour_key] or {}
  bump(stats.hourly[hour_key], p, m, u)

  local day_key = os.date('%Y-%m-%d', now)
  stats.daily[day_key] = stats.daily[day_key] or {}
  bump(stats.daily[day_key], p, m, u)

  M.vacuum(stats, now)
  M.save(stats)
end

--- Merge every bucket at or after a cutoff key into a flat
--- [provider][model] table.
--- @param layer table bucket_key -> [provider][model] = record
--- @param cutoff string lower-bound bucket key (inclusive)
--- @return table
local function merge_since(layer, cutoff)
  local out = {}
  for key, bucket in pairs(layer or {}) do
    if type(bucket) == 'table' and key >= cutoff then
      for p, models in pairs(bucket) do
        if type(models) == 'table' then
          out[p] = out[p] or {}
          for m, rec in pairs(models) do
            if type(rec) == 'table' then
              local acc = out[p][m]
              if type(acc) ~= 'table' then
                acc = { requests = 0 }
              end
              acc.requests = (tonumber(acc.requests) or 0)
                + (tonumber(rec.requests) or 0)
              usage.add(acc, rec)
              out[p][m] = acc
            end
          end
        end
      end
    end
  end
  return out
end

--- All-time totals, [provider][model] = record.
--- @return table
function M.total()
  return M.load().total
end

--- Totals for a time window ending now.
--- Spans >= 48h merge daily buckets, shorter spans merge hourly buckets
--- (finer granularity where it matters). Data past the retention window
--- simply no longer exists, so very old `since` values return whatever
--- is still retained.
--- @param since number unix timestamp (window start)
--- @return table [provider][model] = record
function M.range(since)
  since = tonumber(since) or os.time()
  local stats = M.load()
  if os.time() - since >= 48 * 3600 then
    return merge_since(stats.daily, os.date('%Y-%m-%d', since))
  end
  return merge_since(stats.hourly, os.date('%Y-%m-%dT%H', since))
end

--- Clear all statistics (all three layers).
function M.reset()
  M.save({ total = {}, hourly = {}, daily = {} })
end

return M

