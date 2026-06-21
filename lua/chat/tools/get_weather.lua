-- lua/chat/tools/get_weather.lua
local M = {}

local job = require('job')

local WEATHER_API = 'http://aider.meizu.com/app/weather/listWeather'
local DEFAULT_CITY_ID = '101240101'

local curl_available = nil
local function is_curl_available()
  if curl_available == nil then
    curl_available = vim.fn.executable('curl') == 1
  end
  return curl_available
end

local function normalize_city_id(value)
  if type(value) == 'number' then
    value = string.format('%.0f', value)
  end

  if type(value) ~= 'string' or value == '' then
    return nil
  end

  if not value:match('^%d+$') then
    return nil
  end

  return value
end

local function normalize_city_ids(action)
  local city_ids = {}

  if action.city_ids ~= nil then
    -- Defensive: handle string→array (some LLMs pass a single string instead of array)
    if type(action.city_ids) == 'string' then
      action.city_ids = { action.city_ids }
    end
    if type(action.city_ids) ~= 'table' then
      return nil, 'city_ids must be an array of city ID strings or numbers.'
    end

    for _, city_id in ipairs(action.city_ids) do
      local normalized = normalize_city_id(city_id)
      if not normalized then
        return nil, 'city_ids contains an invalid city ID. City IDs must contain digits only.'
      end
      table.insert(city_ids, normalized)
    end
  elseif action.city_id ~= nil then
    local normalized = normalize_city_id(action.city_id)
    if not normalized then
      return nil, 'city_id must be a string or number containing digits only.'
    end
    table.insert(city_ids, normalized)
  else
    table.insert(city_ids, DEFAULT_CITY_ID)
  end

  if #city_ids == 0 then
    return nil, 'at least one city ID is required.'
  end

  return city_ids, nil
end

---@class ChatToolsGetWeatherAction
---@field city_id? string|number Single city ID, for example 101240101 for 南昌
---@field city_ids? string[]|number[] Multiple city IDs
---@field timeout? integer Timeout in seconds, default 30

---@param action ChatToolsGetWeatherAction
---@param ctx ChatToolContext
function M.get_weather(action, ctx)
  action = action or {}

  if not is_curl_available() then
    return {
      error = 'curl is not installed or not in PATH. Please install curl first.',
    }
  end

  local city_ids, err = normalize_city_ids(action)
  if err then
    return { error = err }
  end

  local timeout = action.timeout or 30
  if type(timeout) ~= 'number' or timeout < 1 or timeout > 300 then
    return {
      error = 'timeout must be between 1 and 300 seconds.',
    }
  end

  local url = WEATHER_API .. '?cityIds=' .. table.concat(city_ids, ',')
  local cmd = {
    'curl',
    '-s',
    '-L',
    '--compressed',
    '--max-time',
    tostring(timeout),
    '--user-agent',
    'Mozilla/5.0 (compatible; chat.nvim)',
    url,
  }

  local stdout = {}
  local stderr = {}

  local jobid = job.start(cmd, {
    on_stdout = function(_, data)
      for _, line in ipairs(data) do
        table.insert(stdout, line)
      end
    end,
    on_stderr = function(_, data)
      for _, line in ipairs(data) do
        table.insert(stderr, line)
      end
    end,
    on_exit = function(id, code, signal)
      require('chat.log').debug(
        'get_weather job '
          .. id
          .. ' exit code '
          .. code
          .. ' signal '
          .. signal
      )

      if signal ~= 0 then
        ctx.callback({
          error = string.format('get_weather cancelled by user (signal: %d)', signal),
          jobid = id,
        })
        return
      end

      local result = table.concat(stdout, '\n')
      local error_output = table.concat(stderr, '\n')

      if code == 0 then
        ctx.callback({
          content = string.format(
            'Successfully fetched weather data.\nURL: %s\nCity IDs: %s\nContent-Length: %d characters\n\n%s',
            url,
            table.concat(city_ids, ', '),
            #result,
            result
          ),
          jobid = id,
        })
        return
      end

      if result ~= '' and error_output ~= '' then
        error_output = result .. '\n\n' .. error_output
      elseif result ~= '' then
        error_output = result
      end

      local error_msg = string.format(
        'Failed to fetch weather data (exit code: %d).\nURL: %s\n\nError output: %s',
        code,
        url,
        error_output
      )

      if code == 6 then
        error_msg = error_msg
          .. '\n\nTroubleshooting: Could not resolve host. Check network connection.'
      elseif code == 7 then
        error_msg = error_msg
          .. '\n\nTroubleshooting: Failed to connect to weather API.'
      elseif code == 28 then
        error_msg = error_msg
          .. '\n\nTroubleshooting: Request timed out. Try increasing timeout.'
      end

      ctx.callback({
        error = error_msg,
        jobid = id,
      })
    end,
  })

  return {
    jobid = jobid,
  }
end

function M.scheme()
  return {
    type = 'function',
    ['function'] = {
      name = 'get_weather',
      description = [[
Get weather data from Meizu weather API.

The tool requests:
http://aider.meizu.com/app/weather/listWeather?cityIds=<city_id>

Use city_id for one city or city_ids for multiple cities. If no city ID is
provided, it defaults to 101240101 (南昌). City IDs are numeric IDs from the
provided city list, for example:
- 101240101: 南昌
- 101010100: 北京
- 101020100: 上海
- 101280601: 深圳
- 101280101: 广州
- 101270101: 成都
- 101210101: 杭州
]],
      parameters = {
        type = 'object',
        properties = {
          city_id = {
            type = 'string',
            -- NOTE: Schema uses type='string' instead of oneOf (string|number)
            -- because many models don't support JSON Schema oneOf properly.
            -- Execution code handles both string and number via normalize_city_id.
            description = 'Single numeric city ID, for example 101240101 for 南昌.',
          },
          city_ids = {
            type = 'array',
            description = 'Multiple numeric city IDs. If provided, city_id is ignored.',
            items = {
              type = 'string',
              description = 'City ID (numeric string, e.g. "101240101")',
            },
          },
          timeout = {
            type = 'integer',
            description = 'Timeout in seconds (default: 30, minimum: 1, maximum: 300).',
            minimum = 1,
            maximum = 300,
          },
        },
      },
    },
  }
end

function M.info(action, ctx)
  local ok, arguments = pcall(vim.json.decode, action)
  if not ok then
    return 'get_weather'
  end

  if arguments.city_ids and type(arguments.city_ids) == 'table' then
    return string.format('get_weather city_ids=%s', table.concat(arguments.city_ids, ','))
  end

  return string.format('get_weather city_id=%s', arguments.city_id or DEFAULT_CITY_ID)
end

return M

