-- test/usage_stats_spec.lua
-- Coverage for chat.usage_stats: three-layer bucket accounting
-- (total / hourly / daily), provider-shape normalization via
-- chat.usage, window queries (range), lazy vacuum against retention
-- config, disable switch, corrupt-file degradation and reset.

local lu = require('luaunit')

local config = require('chat.config')
local usage_stats = require('chat.usage_stats')

TestUsageStats = {}

local storage_dir

function TestUsageStats:setUp()
  storage_dir = vim.fn.tempname() .. '_usage_stats_test/'
  vim.fn.mkdir(storage_dir, 'p')

  config.setup({
    storage_dir = storage_dir,
    usage_stats = {
      enable = true,
      hourly_days = 7,
      daily_days = 365,
    },
  })
end

function TestUsageStats:tearDown()
  if storage_dir and vim.fn.isdirectory(storage_dir) == 1 then
    vim.fn.delete(storage_dir, 'rf')
  end
  storage_dir = nil
end

-- helpers ------------------------------------------------------------

local function path()
  return storage_dir .. 'usage_stats.json'
end

local function read_file_raw()
  local file = io.open(path(), 'r')
  if not file then
    return nil
  end
  local content = file:read('*a')
  file:close()
  return content
end

local function write_file_raw(content)
  local file = io.open(path(), 'w')
  if not file then
    return false
  end
  file:write(content)
  file:close()
  return true
end

local function find_record(t, provider, model)
  return t[provider] and t[provider][model] or nil
end

-- load / save --------------------------------------------------------

function TestUsageStats:test_load_missing_file_returns_zeroed()
  local stats = usage_stats.load()
  lu.assertEquals({ total = {}, hourly = {}, daily = {} }, stats)
end

function TestUsageStats:test_load_corrupt_file_degrades_to_zero()
  write_file_raw('not json at all {{{')
  local stats = usage_stats.load()
  lu.assertEquals({ total = {}, hourly = {}, daily = {} }, stats)
end

function TestUsageStats:test_save_creates_missing_storage_dir()
  -- drop the directory to prove save() rebuilds it
  local nested = storage_dir .. 'nested/'
  config.setup({ storage_dir = nested })
  lu.assertTrue(usage_stats.save({ total = {}, hourly = {}, daily = {} }))
  lu.assertEquals(1, vim.fn.isdirectory(nested))
end

-- record ---------------------------------------------------------------

function TestUsageStats:test_record_writes_three_layers()
  usage_stats.record('deepseek', 'deepseek-chat', {
    prompt_tokens = 100,
    completion_tokens = 20,
  })

  local on_disk = vim.json.decode(read_file_raw())
  local total = find_record(on_disk.total, 'deepseek', 'deepseek-chat')
  lu.assertEquals(1, total.requests)
  lu.assertEquals(120, total.total_tokens)
  lu.assertEquals(100, total.prompt_tokens)
  lu.assertEquals(20, total.completion_tokens)

  local hour_key = os.date('%Y-%m-%dT%H')
  local hourly = find_record(
    on_disk.hourly[hour_key],
    'deepseek',
    'deepseek-chat'
  )
  lu.assertEquals(1, hourly.requests)

  local day_key = os.date('%Y-%m-%d')
  local daily = find_record(
    on_disk.daily[day_key],
    'deepseek',
    'deepseek-chat'
  )
  lu.assertEquals(1, daily.requests)
end

function TestUsageStats:test_record_accumulates()
  usage_stats.record('deepseek', 'deepseek-chat', {
    prompt_tokens = 100,
    completion_tokens = 20,
  })
  usage_stats.record('deepseek', 'deepseek-chat', {
    prompt_tokens = 50,
    completion_tokens = 10,
    cached_tokens = 30,
  })

  local total = find_record(usage_stats.total(), 'deepseek', 'deepseek-chat')
  lu.assertEquals(2, total.requests)
  lu.assertEquals(180, total.total_tokens)
  lu.assertEquals(150, total.prompt_tokens)
  lu.assertEquals(30, total.completion_tokens)
  lu.assertEquals(30, total.cached_tokens)
end

function TestUsageStats:test_record_normalizes_provider_shapes()
  -- deepseek shape
  usage_stats.record('deepseek', 'deepseek-chat', {
    prompt_tokens = 200,
    completion_tokens = 50,
    prompt_cache_hit_tokens = 120,
  })
  -- anthropic shape
  usage_stats.record('anthropic', 'claude-sonnet-4', {
    prompt_tokens = 80,
    completion_tokens = 10,
    cache_read_input_tokens = 60,
  })

  local t1 = find_record(usage_stats.total(), 'deepseek', 'deepseek-chat')
  lu.assertEquals(120, t1.cached_tokens)

  local t2 = find_record(usage_stats.total(), 'anthropic', 'claude-sonnet-4')
  lu.assertEquals(60, t2.cached_tokens)
end

function TestUsageStats:test_record_model_key_sanitize()
  usage_stats.record('openrouter', 'anthropic/claude-sonnet-4', {
    prompt_tokens = 10,
    completion_tokens = 5,
  })

  local total = usage_stats.total()
  lu.assertNotNil(total.openrouter['anthropic:claude-sonnet-4'])
  lu.assertNil(total.openrouter['anthropic/claude-sonnet-4'])
end

function TestUsageStats:test_record_default_keys()
  usage_stats.record(nil, nil, { prompt_tokens = 10 })

  local total = usage_stats.total()
  lu.assertNotNil(total.unknown['(default)'])
end

function TestUsageStats:test_record_disabled()
  config.setup({ usage_stats = { enable = false } })
  usage_stats.record('deepseek', 'deepseek-chat', { prompt_tokens = 10 })
  lu.assertNil(read_file_raw())
  lu.assertEquals({}, usage_stats.total())
end

function TestUsageStats:test_record_survives_corrupt_stats_file()
  write_file_raw('garbage not json')
  usage_stats.record('deepseek', 'deepseek-chat', { prompt_tokens = 10 })

  local total = find_record(usage_stats.total(), 'deepseek', 'deepseek-chat')
  lu.assertEquals(1, total.requests)
  lu.assertEquals(10, total.total_tokens)
end

-- range ----------------------------------------------------------------

function TestUsageStats:test_range_short_window_uses_hourly()
  usage_stats.record('deepseek', 'deepseek-chat', { prompt_tokens = 10 })

  local out = usage_stats.range(os.time() - 5 * 3600)
  local rec = find_record(out, 'deepseek', 'deepseek-chat')
  lu.assertNotNil(rec)
  lu.assertEquals(1, rec.requests)
end

function TestUsageStats:test_range_long_window_uses_daily()
  usage_stats.record('deepseek', 'deepseek-chat', { prompt_tokens = 10 })

  local out = usage_stats.range(os.time() - 7 * 86400)
  local rec = find_record(out, 'deepseek', 'deepseek-chat')
  lu.assertNotNil(rec)
  lu.assertEquals(1, rec.requests)
end

function TestUsageStats:test_range_excludes_older_hourly_buckets()
  -- current hour
  usage_stats.record('deepseek', 'deepseek-chat', { prompt_tokens = 10 })
  -- an old bucket written directly, 10 hours back
  local old_hour = os.date('%Y-%m-%dT%H', os.time() - 10 * 3600)
  local stats = usage_stats.load()
  stats.hourly[old_hour] = {
    deepseek = { ['deepseek-chat'] = { requests = 99, total_tokens = 999 } },
  }
  usage_stats.save(stats)

  local out = usage_stats.range(os.time() - 5 * 3600)
  local rec = find_record(out, 'deepseek', 'deepseek-chat')
  lu.assertEquals(1, rec.requests)
end

function TestUsageStats:test_range_includes_boundary_bucket()
  -- record once in the current hour, then query with a window that
  -- starts inside this same hour: the bucket counts whole
  usage_stats.record('deepseek', 'deepseek-chat', { prompt_tokens = 10 })

  local out = usage_stats.range(os.time() - 3600)
  local rec = find_record(out, 'deepseek', 'deepseek-chat')
  lu.assertEquals(1, rec.requests)
end

function TestUsageStats:test_range_merges_multiple_models()
  usage_stats.record('deepseek', 'deepseek-chat', { prompt_tokens = 10 })
  usage_stats.record('deepseek', 'deepseek-reasoner', { prompt_tokens = 20 })
  usage_stats.record('anthropic', 'claude-sonnet-4', { prompt_tokens = 30 })

  local out = usage_stats.range(os.time() - 3600)
  lu.assertEquals(10, out.deepseek['deepseek-chat'].prompt_tokens)
  lu.assertEquals(20, out.deepseek['deepseek-reasoner'].prompt_tokens)
  lu.assertEquals(30, out.anthropic['claude-sonnet-4'].prompt_tokens)
end

-- vacuum ----------------------------------------------------------------

function TestUsageStats:test_vacuum_drops_expired_hourly_buckets()
  local stats = usage_stats.load()
  local old_hour = os.date('%Y-%m-%dT%H', os.time() - 8 * 86400)
  stats.hourly[old_hour] = {
    deepseek = { ['deepseek-chat'] = { requests = 5 } },
  }
  local recent_day = os.date('%Y-%m-%d')
  stats.daily[recent_day] = {
    deepseek = { ['deepseek-chat'] = { requests = 1 } },
  }

  usage_stats.vacuum(stats, os.time())
  lu.assertNil(stats.hourly[old_hour])
  lu.assertNotNil(stats.daily[recent_day])
end

function TestUsageStats:test_vacuum_drops_expired_daily_buckets()
  local stats = usage_stats.load()
  local old_day = os.date('%Y-%m-%d', os.time() - 400 * 86400)
  stats.daily[old_day] = {
    deepseek = { ['deepseek-chat'] = { requests = 5 } },
  }

  usage_stats.vacuum(stats, os.time())
  lu.assertNil(stats.daily[old_day])
end

function TestUsageStats:test_vacuum_respects_custom_retention()
  config.setup({ usage_stats = { hourly_days = 1, daily_days = 30 } })

  local stats = usage_stats.load()
  local old_hour = os.date('%Y-%m-%dT%H', os.time() - 3 * 86400)
  local old_day = os.date('%Y-%m-%d', os.time() - 60 * 86400)
  stats.hourly[old_hour] = { deepseek = { m = { requests = 1 } } }
  stats.daily[old_day] = { deepseek = { m = { requests = 1 } } }

  usage_stats.vacuum(stats, os.time())
  lu.assertNil(stats.hourly[old_hour])
  lu.assertNil(stats.daily[old_day])
end

function TestUsageStats:test_vacuum_keeps_total()
  local stats = usage_stats.load()
  stats.total['deepseek'] = { ['deepseek-chat'] = { requests = 42 } }

  usage_stats.vacuum(stats, os.time() + 10 * 365 * 86400)
  lu.assertNotNil(stats.total['deepseek'])
end

-- reset ------------------------------------------------------------------

function TestUsageStats:test_reset_clears_everything()
  usage_stats.record('deepseek', 'deepseek-chat', { prompt_tokens = 10 })

  usage_stats.reset()
  lu.assertEquals({}, usage_stats.total())
  lu.assertEquals({}, usage_stats.range(os.time() - 3600))
end

return TestUsageStats

