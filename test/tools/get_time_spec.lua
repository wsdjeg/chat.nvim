-- test/tools/get_time_spec.lua
-- Tests for get_time tool

local lu = require('luaunit')
local get_time = require('chat.tools.get_time')

TestGetTime = {}

--- Test scheme function
function TestGetTime:testScheme()
  local scheme = get_time.scheme()
  lu.assertNotNil(scheme)
  lu.assertEquals(scheme.type, 'function')
  lu.assertEquals(scheme['function'].name, 'get_time')
  lu.assertNotNil(scheme['function'].description)
  lu.assertNotNil(scheme['function'].parameters)
end

--- Test default format (all)
function TestGetTime:testDefaultFormat()
  local result = get_time.get_time({}, {})
  lu.assertNil(result.error)
  lu.assertNotNil(result.content)

  local data = vim.json.decode(result.content)
  lu.assertNotNil(data.iso)
  lu.assertNotNil(data.iso_utc)
  lu.assertNotNil(data.unix)
  lu.assertNotNil(data.human)
  lu.assertNotNil(data.human_utc)
  lu.assertNotNil(data.date)
  lu.assertNotNil(data.relative)
end

--- Test iso format
function TestGetTime:testIsoFormat()
  local result = get_time.get_time({ format = 'iso' }, {})
  lu.assertNil(result.error)

  local data = vim.json.decode(result.content)
  lu.assertNotNil(data.iso)
  lu.assertNotNil(data.iso_utc)
  lu.assertStrContains(data.iso, 'T')
  lu.assertStrContains(data.iso_utc, 'Z')
end

--- Test unix format
function TestGetTime:testUnixFormat()
  local result = get_time.get_time({ format = 'unix' }, {})
  lu.assertNil(result.error)

  local data = vim.json.decode(result.content)
  lu.assertNumber(data.unix)
  lu.assertTrue(data.unix > 0)
end

--- Test human format
function TestGetTime:testHumanFormat()
  local result = get_time.get_time({ format = 'human' }, {})
  lu.assertNil(result.error)

  local data = vim.json.decode(result.content)
  lu.assertNotNil(data.human)
  lu.assertNotNil(data.human_utc)
end

--- Test UTC timezone
function TestGetTime:testUtcTimezone()
  local result = get_time.get_time({ timezone = 'utc' }, {})
  lu.assertNil(result.error)

  local data = vim.json.decode(result.content)
  lu.assertStrContains(data.iso_utc, 'Z')
end

--- Test local timezone
function TestGetTime:testLocalTimezone()
  local result = get_time.get_time({ timezone = 'local' }, {})
  lu.assertNil(result.error)

  local data = vim.json.decode(result.content)
  lu.assertNotNil(data.iso)
end

--- Test date fields
function TestGetTime:testDateFields()
  local result = get_time.get_time({}, {})
  local data = vim.json.decode(result.content)

  lu.assertNotNil(data.date.year)
  lu.assertNotNil(data.date.month)
  lu.assertNotNil(data.date.day)
  lu.assertNotNil(data.date.hour)
  lu.assertNotNil(data.date.minute)
  lu.assertNotNil(data.date.second)
  lu.assertNotNil(data.date.weekday)
  lu.assertNotNil(data.date.weekday_name)
  lu.assertNotNil(data.date.weekday_name_cn)
end

--- Test relative fields
function TestGetTime:testRelativeFields()
  local result = get_time.get_time({}, {})
  local data = vim.json.decode(result.content)

  lu.assertNotNil(data.relative.is_today)
  lu.assertNotNil(data.relative.is_weekend)
  lu.assertNotNil(data.relative.is_workday)
  lu.assertNotNil(data.relative.time_of_day)
end

--- Test time_of_day values
function TestGetTime:testTimeOfDay()
  -- Test all possible time_of_day values by checking format
  local result = get_time.get_time({}, {})
  local data = vim.json.decode(result.content)
  local valid_times = { 'night', 'morning', 'noon', 'afternoon', 'evening' }
  local found = false
  for _, v in ipairs(valid_times) do
    if data.relative.time_of_day == v then
      found = true
      break
    end
  end
  lu.assertTrue(found, 'time_of_day should be one of: night, morning, afternoon, evening')
end

--- Test info function
function TestGetTime:testInfoDefault()
  local info = get_time.info('{}', {})
  lu.assertStrContains(info, 'get_time')
end

function TestGetTime:testInfoWithFormat()
  local info = get_time.info('{"format":"iso"}', {})
  lu.assertStrContains(info, 'format="iso"')
end

function TestGetTime:testInfoWithTimezone()
  local info = get_time.info('{"timezone":"utc"}', {})
  lu.assertStrContains(info, 'timezone="utc"')
end

return TestGetTime
