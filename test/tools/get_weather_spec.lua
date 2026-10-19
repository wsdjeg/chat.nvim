local lu = require('luaunit')
local tools = require('chat.tools')
local config = require('chat.config')
local get_weather = require('chat.tools.get_weather')
local curl = require('chat.curl')

local function call_async_tool(func, arguments, ctx, timeout)
  timeout = timeout or 5000
  local result_received = false
  local actual_result = nil
  local result = tools.call(
    func,
    arguments,
    vim.tbl_extend('force', ctx, {
      callback = function(res)
        result_received = true
        actual_result = res
      end,
    })
  )
  if result.error then
    return result
  end
  local wait_ok = vim.wait(timeout, function()
    return result_received
  end, 50)
  if not wait_ok then
    return { error = 'Async tool did not complete within ' .. timeout .. 'ms' }
  end
  return actual_result
end

local function mock_curl_success()
  curl.is_available = function() return true end
  curl.build_request = function() return { 'echo', '{"weather":[{}]}' } end
end

local function mock_curl_failure()
  curl.is_available = function() return true end
  curl.build_request = function() return { 'sh', '-c', 'exit 3' } end
end

TestGetWeather = {}

function TestGetWeather:setUp()
  self.cwd = vim.fs.normalize(vim.fn.getcwd())
  config.setup({ allowed_path = self.cwd })
  self._orig_avail = curl.is_available
  self._orig_build = curl.build_request
  self._orig_get_err = curl.get_error_message
end

function TestGetWeather:tearDown()
  curl.is_available = self._orig_avail
  curl.build_request = self._orig_build
  curl.get_error_message = self._orig_get_err
end

function TestGetWeather:testCurlUnavailable()
  curl.is_available = function() return false end
  local result = tools.call('get_weather', {}, { cwd = self.cwd })
  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'curl is not installed')
end

function TestGetWeather:testCityIdsNotArray()
  mock_curl_success()
  local result = tools.call('get_weather', { city_ids = 123 }, { cwd = self.cwd })
  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'city_ids must be an array')
end

function TestGetWeather:testCityIdsInvalidEntry()
  mock_curl_success()
  local result = tools.call('get_weather', { city_ids = { 'abc' } }, { cwd = self.cwd })
  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'invalid city ID')
end

function TestGetWeather:testCityIdInvalid()
  mock_curl_success()
  local result = tools.call('get_weather', { city_id = 'abc' }, { cwd = self.cwd })
  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'city_id must be a string or number')
end

function TestGetWeather:testCityIdNumber()
  mock_curl_success()
  -- Valid numeric city id: should proceed past validation, trigger job
  local result = call_async_tool('get_weather', {
    city_id = 101240101,
  }, { cwd = self.cwd })
  lu.assertNotNil(result)
  lu.assertNotNil(result.content, 'Expected content, got error: ' .. (result.error or 'unknown'))
  lu.assertStrContains(result.content, 'Successfully fetched weather data')
end

function TestGetWeather:testCityIdsArray()
  mock_curl_success()
  local result = call_async_tool('get_weather', {
    city_ids = { '101240101', '101010100' },
  }, { cwd = self.cwd })
  lu.assertNotNil(result)
  lu.assertNotNil(result.content, 'Expected content, got error: ' .. (result.error or 'unknown'))
end

function TestGetWeather:testDefaultCityId()
  mock_curl_success()
  local result = call_async_tool('get_weather', {}, { cwd = self.cwd })
  lu.assertNotNil(result)
  lu.assertNotNil(result.content, 'Expected content, got error: ' .. (result.error or 'unknown'))
end

function TestGetWeather:testTimeoutInvalid()
  mock_curl_success()
  local result = tools.call('get_weather', { timeout = 0 }, { cwd = self.cwd })
  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'timeout must be between 1 and 300')
end

function TestGetWeather:testTimeoutTooLarge()
  mock_curl_success()
  local result = tools.call('get_weather', { timeout = 301 }, { cwd = self.cwd })
  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'timeout must be between 1 and 300')
end

function TestGetWeather:testTimeoutNonNumber()
  mock_curl_success()
  local result = tools.call('get_weather', { timeout = 'fast' }, { cwd = self.cwd })
  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'timeout must be between 1 and 300')
end

function TestGetWeather:testCurlFailure()
  mock_curl_failure()
  curl.get_error_message = function() return 'some hint' end
  local result = call_async_tool('get_weather', {
    city_id = '101240101',
  }, { cwd = self.cwd })
  lu.assertNotNil(result)
  lu.assertNotNil(result.error)
  lu.assertStrContains(result.error, 'Failed to fetch weather data')
end

function TestGetWeather:testInfoDefault()
  local info = get_weather.info('not json', { cwd = self.cwd })
  lu.assertEquals('get_weather', info)
end

function TestGetWeather:testInfoCityIds()
  local info = get_weather.info(
    vim.json.encode({ city_ids = { '101240101', '101010100' } }),
    { cwd = self.cwd }
  )
  lu.assertStrContains(info, 'city_ids=101240101,101010100')
end

function TestGetWeather:testInfoCityId()
  local info = get_weather.info(
    vim.json.encode({ city_id = '101010100' }),
    { cwd = self.cwd }
  )
  lu.assertStrContains(info, 'city_id=101010100')
end

function TestGetWeather:testInfoDefaultCity()
  local info = get_weather.info('{}', { cwd = self.cwd })
  lu.assertStrContains(info, 'city_id=101240101')
end

function TestGetWeather:testScheme()
  local scheme = get_weather.scheme()
  lu.assertEquals('function', scheme.type)
  lu.assertEquals('get_weather', scheme['function'].name)
end

return TestGetWeather
