-- lua/chat/icons.lua
-- User-visible glyphs for the terminal UI (chat window labels, tool / status
-- lines and floating window title pills).
--
-- Icons are configured through `require('chat').setup({ icons = { ... } })`.
--
-- Two rules make validation non-trivial:
--
-- 1. A value has to *look* like one character. `#value` is byte based and
--    wrong for anything but ASCII, so the check uses `strchars()` after
--    dropping a variation selector (U+FE0F), otherwise a perfectly normal
--    `❤️` (U+2764 U+FE0F) would be rejected as "two characters" while it only
--    occupies one cell.
-- 2. An icon ends up inside a Vim regex (`matchadd` highlights the message
--    prefix). A character class like `[🤖👤❌🔁]` only works because those
--    emoji happen to be harmless; an icon such as `]`, `^`, `\` or `*` would
--    silently break the pattern. Icons are therefore joined as escaped
--    alternatives inside a `\%(` non-capturing group, never as a class.
--
-- Validation runs once, in `chat.config.setup()`, so the rest of the codebase
-- can read the values without re-checking them.

local M = {}

--- Bytes of U+FE0F (VARIATION SELECTOR-16). Dropped before counting chars.
local VS16 = '\239\184\143'

--- Characters that must be backslash-escaped to stay literal in a Vim regex
--- written in *magic* mode (the default).
---
--- Only these: `(`, `)`, `|`, `{`, `}` and `+`, `?` are *already* literal in
--- magic mode, and escaping them would do the opposite - `\(` opens a group,
--- `\|` becomes an alternation. An icon like `)` therefore has to stay bare,
--- otherwise it would leave an unclosed group behind.
local MAGIC = {
  ['\\'] = true,
  ['['] = true,
  [']'] = true,
  ['.'] = true,
  ['*'] = true,
  ['^'] = true,
  ['$'] = true,
  ['~'] = true,
}

--- Pristine defaults. Read from `chat.config` lazily (that module ships
--- `icon_defaults` separately from the live config), so a repeated `setup()`
--- call that installs a temporary icon cannot change what an invalid value
--- falls back to.
--- @return table<string, string>
local function defaults()
  return vim.deepcopy(require('chat.config').icon_defaults)
end

--- Drop variation selectors so an emoji sequence counts as one displayed char.
--- @param value string
--- @return string
local function without_vs16(value)
  return (value:gsub(VS16, ''))
end

--- Whether a value is usable as an icon.
---
--- Accepted: `''` (explicitly disabled, the icon is simply not drawn) or a
--- single displayed character 1-2 cells wide.
--- Rejected: non-strings, control characters, multi-character strings
--- (`'AB'`, `'🤖👤'`) and zero-width / combining marks.
--- @param value any
--- @return boolean
function M.is_valid(value)
  if type(value) ~= 'string' then
    return false
  end
  if value == '' then
    return true
  end
  if value:find('%c') then
    return false
  end
  if vim.fn.strchars(without_vs16(value)) ~= 1 then
    return false
  end
  local width = vim.fn.strdisplaywidth(value)
  return width >= 1 and width <= 2
end

--- Validate a user supplied `icons` table and fill in the defaults.
---
--- Invalid values and unknown keys fall back to the default and are reported
--- through `chat.log`, so one typo degrades a single glyph instead of
--- poisoning the whole table (or throwing during startup).
--- @param user_icons any value passed as `setup({ icons = ... })`
--- @return table<string, string> complete, validated icon table
function M.sanitize(user_icons)
  local result = defaults()
  local log = require('chat.log')
  if type(user_icons) ~= 'table' then
    log.error(
      'icons must be a table, got ' .. type(user_icons) .. ', using defaults'
    )
    return result
  end
  for key, value in pairs(user_icons) do
    if result[key] == nil then
      log.error('icons: unknown key "' .. tostring(key) .. '" ignored')
    elseif not M.is_valid(value) then
      log.error(
        string.format(
          'icons.%s must be a single character, got %s, using %s',
          key,
          tostring(value),
          result[key]
        )
      )
    else
      result[key] = value
    end
  end
  return result
end

--- Read one icon from the live config.
--- @param name string icon key (bot / user / tool / success / error / notice / cache)
--- @return string icon, `''` when the icon is disabled or unknown
function M.get(name)
  local live = require('chat.config').config.icons
  if type(live) == 'table' and type(live[name]) == 'string' then
    return live[name]
  end
  local fallback = defaults()[name]
  return fallback or ''
end

--- Icon followed by one space, or `''` when the icon is disabled.
---
--- Callers format the icon as `'%s%d%%'` instead of hardcoding the surrounding
--- spaces, so a disabled icon leaves `' 45%'` behind rather than `' 💾 45%'`
--- with a hole in it.
--- @param name string icon key
--- @return string
function M.padded(name)
  local icon = M.get(name)
  if icon == '' then
    return ''
  end
  return icon .. ' '
end

--- Escape one icon so it matches literally in a magic-mode Vim regex.
---
--- Byte-wise on purpose: multi-byte characters are never magic, so their
--- bytes pass through untouched and are re-joined verbatim.
--- @param icon string
--- @return string
local function escape(icon)
  local out = {}
  for i = 1, #icon do
    local char = icon:sub(i, i)
    out[#out + 1] = MAGIC[char] and ('\\' .. char) or char
  end
  return table.concat(out)
end

--- Pattern matching the leading `[time] <icon>` prefix of a message line.
---
--- Built as `\%(icon1\|icon2\|...\)` - escaped alternatives inside a
--- non-capturing group - instead of a character class, because a class needs
--- byte-wise members and breaks as soon as one icon is `]`, `^` or `\`.
--- Note that in magic mode the group is `\%(`, the alternation is `\|`, and
--- plain `(` / `|` are literals; using PCRE syntax here would silently
--- produce a pattern that never matches.
--- Disabled icons are skipped, and when every role icon is disabled the
--- function returns nil so the caller can skip `matchadd` entirely.
--- @return string|nil Vim regex, or nil when every role icon is disabled
function M.role_pattern()
  local alternatives = {}
  for _, name in ipairs({ 'bot', 'user', 'error', 'notice' }) do
    local icon = M.get(name)
    if icon ~= '' then
      alternatives[#alternatives + 1] = escape(icon)
    end
  end
  if #alternatives == 0 then
    return nil
  end
  return '^\\[[^]]*\\] \\%(' .. table.concat(alternatives, '\\|') .. '\\)'
end

return M

