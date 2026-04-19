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
  return vim.fn.has('win32') == 1 or vim.fn.has('win64') == 1
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
---@param path string The path to check (should be normalized absolute path)
---@return boolean
function M.is_allowed_path(path)
  local config = require('chat.config')
  local normalized_path = vim.fs.normalize(path)

  local allowed_path = config.config.allowed_path

  if type(allowed_path) == 'table' then
    for _, v in ipairs(allowed_path) do
      if type(v) == 'string' and #v > 0 then
        if vim.startswith(normalized_path, vim.fs.normalize(v)) then
          return true
        end
      end
    end
  elseif
    type(allowed_path) == 'string'
    and #allowed_path > 0
  then
    return vim.startswith(
      normalized_path,
      vim.fs.normalize(allowed_path)
    )
  end
  return false
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
