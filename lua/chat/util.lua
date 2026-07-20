local M = {}
local bit = require('bit')

local DISCORD_EPOCH = 1420070400000

function M.buf_set_lines(buf, from, to, lines)
  local modifiable =
    vim.api.nvim_get_option_value('modifiable', { buf = buf })
  vim.api.nvim_set_option_value('modifiable', true, { buf = buf })
  vim.api.nvim_buf_set_lines(buf, from, to, false, lines)
  vim.api.nvim_set_option_value('modifiable', modifiable, { buf = buf })
end

function M.iso_to_snowflake(iso)
  local year, month, day, hour, minute, second, millisecond =
    iso:match('(%d+)%-(%d+)%-(%d+)T(%d+):(%d+):(%d+)%.(%d+)')

  local timestamp = os.time({
    year = year,
    month = month,
    day = day,
    hour = hour,
    min = minute,
    sec = second,
  })

  local timestamp_ms = timestamp * 1000 + tonumber(millisecond)

  return bit.lshift(timestamp_ms - DISCORD_EPOCH, 22)
end
local function is_windows()
  local uname = vim.uv.os_uname()
  return uname.sysname:lower():find('windows') ~= nil
end
local function is_absolute(path)
  if is_windows() then
    if path:match('^%a:[/\\]') then
      return true
    end
    if path:match('^[/\\][/\\]') then
      return true
    end
    return false
  else
    return path:sub(1, 1) == '/'
  end
end

function M.transform(tbl)
  -- Add defensive check for nil or non-table input
  -- This prevents errors when JSON parsing fails and tool_calls is nil
  if not tbl or type(tbl) ~= 'table' then
    return {}
  end

  -- Check if table is empty (no keys)
  local next_key = next(tbl)
  if next_key == nil then
    return {}
  end

  local keys = {}
  for key, _ in pairs(tbl) do
    table.insert(keys, key)
  end
  table.sort(keys)
  local result = {}
  for _, v in ipairs(keys) do
    table.insert(result, tbl[v])
  end
  return result
end

function M.resolve(path, cwd)
  if type(path) ~= 'string' or path == '' then
    return nil
  end

  local full
  if is_absolute(path) then
    full = path
  else
    full = cwd .. '/' .. path
  end

  return vim.fs.normalize(vim.fn.fnamemodify(full, ':p'))
end
--- Check if a path is within allowed_path configuration
--- Ensures directory boundary to prevent path escape (e.g., /home/user/foo should not match /home/user/foobar)
---@param path string The path to check (should be normalized absolute path)
---@return boolean
function M.is_allowed_path(path)
  local config = require('chat.config')
  local normalized_path = vim.fs.normalize(path)

  local allowed_path = config.config.allowed_path

  if type(allowed_path) == 'table' then
    for _, v in ipairs(allowed_path) do
      if type(v) == 'string' and #v > 0 then
        local normalized_allowed = vim.fs.normalize(v)
        if
          normalized_path == normalized_allowed
          or vim.startswith(normalized_path, normalized_allowed .. '/')
        then
          return true
        end
      end
    end
  elseif
    type(allowed_path) == 'string'
    and #allowed_path > 0
  then
    local normalized_allowed = vim.fs.normalize(allowed_path)
    return normalized_path == normalized_allowed
      or vim.startswith(normalized_path, normalized_allowed .. '/')
  end
  return false
end


--- Sanitize a string to ensure it contains only valid UTF-8.
--- Invalid byte sequences are replaced with the Unicode replacement character (U+FFFD).
---@param str string Input string that may contain invalid UTF-8
---@return string sanitized, boolean had_invalid
function M.sanitize_utf8(str)
  if not str or str == '' then
    return str, false
  end

  local result = {}
  local i = 1
  local len = #str
  local had_invalid = false
  local REPL = '\xEF\xBF\xBD' -- U+FFFD in UTF-8

  while i <= len do
    local b = str:byte(i)

    if b < 0x80 then
      -- ASCII: 0xxxxxxx
      result[#result + 1] = str:sub(i, i)
      i = i + 1
    elseif b >= 0xC2 and b <= 0xDF then
      -- 2-byte: 110xxxxx 10xxxxxx
      local b2 = str:byte(i + 1)
      if b2 and b2 >= 0x80 and b2 <= 0xBF then
        result[#result + 1] = str:sub(i, i + 1)
        i = i + 2
      else
        result[#result + 1] = REPL
        had_invalid = true
        i = i + 1
      end
    elseif b >= 0xE0 and b <= 0xEF then
      -- 3-byte: 1110xxxx 10xxxxxx 10xxxxxx
      local b2 = str:byte(i + 1)
      local b3 = str:byte(i + 2)
      local valid = b2 and b3
        and b2 >= 0x80 and b2 <= 0xBF
        and b3 >= 0x80 and b3 <= 0xBF
      if valid and b == 0xE0 and b2 < 0xA0 then valid = false end
      if valid and b == 0xED and b2 > 0x9F then valid = false end -- surrogates
      if valid then
        result[#result + 1] = str:sub(i, i + 2)
        i = i + 3
      else
        result[#result + 1] = REPL
        had_invalid = true
        i = i + 1
      end
    elseif b >= 0xF0 and b <= 0xF4 then
      -- 4-byte: 11110xxx 10xxxxxx 10xxxxxx 10xxxxxx
      local b2 = str:byte(i + 1)
      local b3 = str:byte(i + 2)
      local b4 = str:byte(i + 3)
      local valid = b2 and b3 and b4
        and b2 >= 0x80 and b2 <= 0xBF
        and b3 >= 0x80 and b3 <= 0xBF
        and b4 >= 0x80 and b4 <= 0xBF
      if valid and b == 0xF0 and b2 < 0x90 then valid = false end
      if valid and b == 0xF4 and b2 > 0x8F then valid = false end
      if valid then
        result[#result + 1] = str:sub(i, i + 3)
        i = i + 4
      else
        result[#result + 1] = REPL
        had_invalid = true
        i = i + 1
      end
    else
      -- Invalid leading byte (0x80-0xBF, 0xC0-0xC1, 0xF5-0xFF)
      result[#result + 1] = REPL
      had_invalid = true
      i = i + 1
    end
  end

  return table.concat(result), had_invalid
end

function M.format_number(num)
  if num == nil then
    return '0'
  end
  if num >= 1000000000 then
    return string.format('%.2fG', num / 1000000000)
  elseif num >= 1000000 then
    return string.format('%.1fM', num / 1000000)
  elseif num >= 1000 then
    return string.format('%.1fK', num / 1000)
  else
    return tostring(num)
  end
end

return M
