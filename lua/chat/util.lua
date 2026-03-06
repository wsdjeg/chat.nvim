local M = {}
local bit = require('bit')

local DISCORD_EPOCH = 1420070400000

function M.iso_to_snowflake(iso)
  local y, m, d, H, M, S, ms =
    iso:match('(%d+)%-(%d+)%-(%d+)T(%d+):(%d+):(%d+)%.(%d+)')

  local t = os.time({
    year = y,
    month = m,
    day = d,
    hour = H,
    min = M,
    sec = S,
  })

  local timestamp_ms = t * 1000 + tonumber(ms)

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

return M
