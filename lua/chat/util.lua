local M = {}
local bit = require('bit')
local log = require('chat.log')

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

--- Check if a path is inside a .git directory.
--- Blocks access to .git itself and anything beneath it.
--- e.g. /project/.git, /project/.git/config, /project/.git/refs/heads/main
--- Does NOT block /project/.github/workflows/ci.yml
---@param path string The path to check (should be normalized absolute path)
---@return boolean true if path is inside .git
function M.is_git_path(path)
  if type(path) ~= 'string' or path == '' then
    return false
  end
  local normalized = vim.fs.normalize(path)
  -- Match /.git at end, or /.git/ anywhere in the path
  return normalized:match('/%.git$') ~= nil
    or normalized:match('/%.git/') ~= nil
end

--- Check if a path is within allowed_path configuration
--- Ensures directory boundary to prevent path escape (e.g., /home/user/foo should not match /home/user/foobar)
--- Also blocks access to .git directories for security
---@param path string The path to check (should be normalized absolute path)
---@return boolean
function M.is_allowed_path(path)
  -- Block all access to .git directories
  if M.is_git_path(path) then
    return false
  end

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

--- Find the position of the first invalid UTF-8 byte in a string.
--- Uses the same validation rules as sanitize_utf8.
---@param str string Input string
---@return number|nil position 1-based byte offset, nil when fully valid
function M.find_invalid_utf8(str)
  if not str or str == '' then
    return nil
  end
  local i, len = 1, #str
  while i <= len do
    local b = str:byte(i)
    if b < 0x80 then
      i = i + 1
    elseif b >= 0xC2 and b <= 0xDF then
      local b2 = str:byte(i + 1)
      if b2 and b2 >= 0x80 and b2 <= 0xBF then
        i = i + 2
      else
        return i
      end
    elseif b >= 0xE0 and b <= 0xEF then
      local b2, b3 = str:byte(i + 1), str:byte(i + 2)
      local valid = b2 and b3
        and b2 >= 0x80 and b2 <= 0xBF
        and b3 >= 0x80 and b3 <= 0xBF
      if valid and b == 0xE0 and b2 < 0xA0 then valid = false end
      if valid and b == 0xED and b2 > 0x9F then valid = false end
      if valid then
        i = i + 3
      else
        return i
      end
    elseif b >= 0xF0 and b <= 0xF4 then
      local b2, b3, b4 = str:byte(i + 1), str:byte(i + 2), str:byte(i + 3)
      local valid = b2 and b3 and b4
        and b2 >= 0x80 and b2 <= 0xBF
        and b3 >= 0x80 and b3 <= 0xBF
        and b4 >= 0x80 and b4 <= 0xBF
      if valid and b == 0xF0 and b2 < 0x90 then valid = false end
      if valid and b == 0xF4 and b2 > 0x8F then valid = false end
      if valid then
        i = i + 4
      else
        return i
      end
    else
      return i
    end
  end
  return nil
end

--- Render a hex-dump context around a byte position for diagnostics.
--- Returns hex bytes and a readable preview (non-printable bytes as '.').
local function hex_context(str, pos)
  local from = math.max(1, pos - 32)
  local to = math.min(#str, pos + 32)
  local hex, txt = {}, {}
  for i = from, to do
    local b = str:byte(i)
    hex[#hex + 1] = string.format('%02X', b)
    if b >= 0x20 and b < 0x7F then
      txt[#txt + 1] = string.char(b)
    else
      txt[#txt + 1] = '.'
    end
  end
  return table.concat(hex, ' '), table.concat(txt)
end

--- Encode a request body to JSON, guaranteeing valid UTF-8 output.
--- vim.json.encode passes invalid UTF-8 bytes through, and strict providers
--- (DashScope) reject the whole request with InvalidParameter.NonUTF8Body.
--- This is the last line of defense: whatever leaked past upstream field
--- sanitization gets repaired here, and the first invalid byte position is
--- logged with a hex context so the leaking source can be identified.
---@param tbl table Body table to encode
---@param label string|nil Provider label for log messages
---@return string encoded JSON body, always valid UTF-8
function M.encode_json_body(tbl, label)
  local body = vim.json.encode(tbl)
  local pos = M.find_invalid_utf8(body)
  if pos then
    local sanitized = M.sanitize_utf8(body)
    local hex, txt = hex_context(body, pos)
    log.warn(string.format(
      '%s: request body contained invalid UTF-8 at byte %d (0x%02X), '
        .. 'replaced with U+FFFD before sending. Context:\n  hex: %s\n  txt: %s',
      label or 'provider', pos, body:byte(pos), hex, txt))
    return sanitized
  end
  return body
end

--- Truncate a string to at most max_bytes bytes, without breaking UTF-8 characters.
--- If max_bytes falls in the middle of a multi-byte character, the cut is moved
--- back to the nearest valid character boundary.
---@param str string Input string (should be valid UTF-8)
---@param max_bytes integer Maximum number of bytes to keep
---@return string truncated
function M.utf8_truncate(str, max_bytes)
  if not str or str == '' or max_bytes <= 0 then
    return ''
  end
  if #str <= max_bytes then
    return str
  end

  -- Find the last valid UTF-8 boundary at or before max_bytes.
  -- Walk backwards from max_bytes to skip any trailing continuation bytes
  -- (0x80-0xBF) that belong to a multi-byte character started before max_bytes
  -- but not completed by max_bytes.
  local pos = max_bytes
  local end_pos = 0
  while pos >= 1 do
    local b = str:byte(pos)
    if b < 0x80 or b >= 0xC0 then
      -- ASCII byte or leading byte of a multi-byte sequence.
      -- Check if the full sequence fits within max_bytes.
      local seq_len
      if b < 0x80 then
        seq_len = 1
      elseif b <= 0xDF then
        seq_len = 2
      elseif b <= 0xEF then
        seq_len = 3
      else
        seq_len = 4
      end
      if pos + seq_len - 1 <= max_bytes then
        -- Complete sequence, end after it
        end_pos = pos + seq_len - 1
        break
      else
        -- Sequence extends past max_bytes, trim it entirely
        pos = pos - 1
      end
    else
      -- Continuation byte (0x80-0xBF), keep walking back
      pos = pos - 1
    end
  end

  return str:sub(1, end_pos)
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

