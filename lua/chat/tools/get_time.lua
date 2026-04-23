-- lua/chat/tools/get_time.lua
-- Tool for getting current time and date information

local M = {}

---@class ChatToolsGetTimeAction
---@field timezone? string Timezone: "local" or "utc" (default: "local")
---@field format? string Output format: "iso", "unix", "human", or "all" (default: "all")

local WEEKDAY_NAMES = {
  'Sunday',
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
}

local WEEKDAY_NAMES_CN = {
  '星期日',
  '星期一',
  '星期二',
  '星期三',
  '星期四',
  '星期五',
  '星期六',
}

--- Build complete time result
---@param now integer Unix timestamp
---@param timezone string
---@return table
local function build_time_result(now, timezone)
  -- Get local time
  local local_time = os.date('*t', now)
  local utc_time = os.date('!*t', now)

  -- Get timezone offset (in seconds)
  local local_ts = os.time(local_time)
  local utc_ts = os.time(utc_time)
  local offset_seconds = local_ts - utc_ts

  -- Format offset as +HH:MM or -HH:MM
  local offset_sign = offset_seconds >= 0 and '+' or '-'
  offset_seconds = math.abs(offset_seconds)
  local offset_hours = math.floor(offset_seconds / 3600)
  local offset_minutes = math.floor((offset_seconds % 3600) / 60)
  local offset_str = string.format('%s%02d:%02d', offset_sign, offset_hours, offset_minutes)

  -- Determine which time to use based on timezone
  local time = timezone == 'utc' and utc_time or local_time
  local ts = timezone == 'utc' and utc_ts or local_ts

  -- ISO 8601 format
  local iso_str
  if timezone == 'utc' then
    iso_str = os.date('!%Y-%m-%dT%H:%M:%SZ', now)
  else
    iso_str = string.format('%sT%s%s', os.date('%Y-%m-%d', ts), os.date('%H:%M:%S', ts), offset_str)
  end

  -- ISO UTC (always UTC)
  local iso_utc = os.date('!%Y-%m-%dT%H:%M:%SZ', now)

  -- Unix timestamp
  local unix_ts = now

  -- Human readable format
  local human_str = string.format(
    '%d年%d月%d日 %s %02d:%02d:%02d',
    time.year,
    time.month,
    time.day,
    WEEKDAY_NAMES_CN[time.wday],
    time.hour,
    time.min,
    time.sec
  )

  local human_utc_str = string.format(
    '%04d-%02d-%02d %s %02d:%02d:%02d UTC',
    utc_time.year,
    utc_time.month,
    utc_time.day,
    WEEKDAY_NAMES[utc_time.wday],
    utc_time.hour,
    utc_time.min,
    utc_time.sec
  )

  -- Determine time of day
  local time_of_day
  if time.hour < 6 then
    time_of_day = 'night'
  elseif time.hour < 12 then
    time_of_day = 'morning'
  elseif time.hour < 14 then
    time_of_day = 'noon'
  elseif time.hour < 18 then
    time_of_day = 'afternoon'
  elseif time.hour < 22 then
    time_of_day = 'evening'
  else
    time_of_day = 'night'
  end

  -- Check if today is weekend (Saturday=6, Sunday=7 in wday)
  local is_weekend = time.wday == 1 or time.wday == 7

  -- Build complete result
  return {
    iso = iso_str,
    iso_utc = iso_utc,
    unix = unix_ts,
    human = human_str,
    human_utc = human_utc_str,
    date = {
      year = time.year,
      month = time.month,
      day = time.day,
      hour = time.hour,
      minute = time.min,
      second = time.sec,
      weekday = time.wday,
      weekday_name = WEEKDAY_NAMES[time.wday],
      weekday_name_cn = WEEKDAY_NAMES_CN[time.wday],
    },
    timezone = {
      name = timezone,
      offset = offset_str,
      offset_seconds = offset_seconds * (offset_sign == '+' and 1 or -1),
    },
    relative = {
      is_today = true,
      is_weekend = is_weekend,
      is_workday = not is_weekend,
      time_of_day = time_of_day,
    },
  }
end

--- Get tool schema for LLM
---@return table Tool schema
function M.scheme()
  return {
    type = 'function',
    ['function'] = {
      name = 'get_time',
      description = [[Get current time and date information.

Supports multiple output formats:
- iso: ISO 8601 format (e.g., "2025-01-10T14:30:00+08:00")
- unix: Unix timestamp (e.g., 1736490600)
- human: Human-readable format (e.g., "2025年1月10日 星期五 14:30:00")
- all: Complete information including date details and relative info (default)

Supports timezones:
- local: Local timezone (default)
- utc: UTC timezone

Examples:
- get_time() — Get complete time information
- get_time(format="iso") — Get ISO format only
- get_time(timezone="utc") — Get UTC time
- get_time(format="unix") — Get Unix timestamp only
]],
      parameters = {
        type = 'object',
        properties = {
          timezone = {
            type = 'string',
            enum = { 'local', 'utc' },
            description = 'Timezone: "local" or "utc" (default: "local")',
          },
          format = {
            type = 'string',
            enum = { 'iso', 'unix', 'human', 'all' },
            description = 'Output format (default: "all")',
          },
        },
        required = {},
      },
    },
  }
end

--- Handle tool call
---@param action ChatToolsGetTimeAction
---@param ctx ChatToolContext
---@return table Result { content } or { error }
function M.get_time(action, ctx)
  action = action or {}

  -- Validate timezone
  local timezone = action.timezone or 'local'
  if timezone ~= 'local' and timezone ~= 'utc' then
    return { error = string.format('Invalid timezone: %s. Must be "local" or "utc".', timezone) }
  end

  -- Validate format
  local format = action.format or 'all'
  if format ~= 'iso' and format ~= 'unix' and format ~= 'human' and format ~= 'all' then
    return { error = string.format('Invalid format: %s. Must be "iso", "unix", "human", or "all".', format) }
  end

  -- Get current time
  local now = os.time()

  -- Build result based on format
  if format == 'all' then
    local result = build_time_result(now, timezone)
    return { content = vim.json.encode(result) }
  elseif format == 'iso' then
    local result = build_time_result(now, timezone)
    return { content = vim.json.encode({ iso = result.iso }) }
  elseif format == 'unix' then
    return { content = vim.json.encode({ unix = now }) }
  else -- format == 'human'
    local result = build_time_result(now, timezone)
    return { content = vim.json.encode({ human = result.human }) }
  end
end

--- Format tool info for display
---@param action string|table
---@return string Formatted info
function M.info(action, _)
  local arguments = action
  if type(action) == 'string' then
    local ok, decoded = pcall(vim.json.decode, action)
    if ok then
      arguments = decoded
    else
      return 'get_time'
    end
  end

  local timezone = arguments.timezone or 'local'
  local format = arguments.format or 'all'
  return string.format('get_time(timezone="%s", format="%s")', timezone, format)
end

return M
