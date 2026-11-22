-- lua/chat/windows/complete.lua
-- Skill completion for the prompt window (CTRL-X CTRL-U).
--
-- The prompt buffer points 'completefunc' at the function below, so insert-mode
-- CTRL-X CTRL-U completes slash commands without an extra keymap.
--
-- Vim calls 'completefunc' twice per round:
--
--   findstart == 1 -> return the byte column where the completed token starts,
--                     or -3 to cancel the round
--   findstart == 0 -> return the candidates for `base`
--
-- Two contexts are completed, both derived from the text before the cursor:
--
--   /cle         -> skill names; the skill description goes into the popup
--                   menu (and into `info`, shown when 'completeopt' has "preview")
--   /model gp    -> arguments, delegated to the skill's optional
--                   `complete(args)` function (ChatSkill.complete)
--
-- Anything else cancels the round, so <C-x><C-u> in the middle of a sentence
-- leaves the buffer untouched instead of replacing ordinary words.
--
-- 'completefunc' is evaluated as a Vimscript expression, and `v:lua.<name>`
-- (a bare global reference) is rejected as an invalid expression on recent
-- Neovim versions, so the option cannot point straight at a Lua function.
-- Instead a thin global Vimscript wrapper is defined once, and it reaches the
-- Lua implementation through `luaeval()`, which is stable across versions.

local M = {}

local skills = require('chat.skills')

-- Name of the global Vimscript wrapper used as 'completefunc'.
M.VIM_FUNC_NAME = 'ChatNvimSkillComplete'

-- Skill descriptions are one-liners; the popup menu is one line as well.
M.MENU_WIDTH = 48

--- Collapse a description onto one line and cut it to `width` characters.
--- @param text string
--- @param width? integer defaults to M.MENU_WIDTH
--- @return string
function M.truncate(text, width)
  width = width or M.MENU_WIDTH
  text = (text or ''):gsub('[\r\n]+', ' ')
  if vim.fn.strchars(text) <= width then
    return text
  end
  return vim.fn.strcharpart(text, 0, width - 1) .. '…'
end

--- Work out what the cursor at byte column `col` of `line` is completing.
---
--- The token under the cursor ends at the cursor and starts after the last
--- whitespace, the same boundaries Vim's 'completefunc' uses.
---
--- @param line string prompt line text
--- @param col integer 0-based byte column of the cursor
--- @return table|nil ctx { kind = 'name'|'args', start = integer, base = string, skill? = ChatSkill }
function M.context(line, col)
  local before = line:sub(1, col)
  local token = before:match('([^%s]*)$') or ''
  local start = col - #token

  -- A token that begins with "/" is a skill name being typed.
  if line:sub(start + 1, start + 1) == '/' then
    -- Skill names never contain a slash, so "/tmp/foo" is a path rather than a
    -- command: cancel instead of replacing the path with a skill name.
    if token:find('/', 2, true) then
      return nil
    end
    return { kind = 'name', start = start, base = token }
  end

  -- Otherwise the token can only be the argument of "/name <token>", and only
  -- skills that ship a `complete` function can suggest anything for it.
  local name = line:sub(1, start):match('^%s*/([^%s]+)%s+$')
  if not name then
    return nil
  end

  local skill = skills.get(name)
  if not skill or type(skill.complete) ~= 'function' then
    return nil
  end

  return { kind = 'args', start = start, base = token, skill = skill }
end

--- Build the candidate list for skill names matching `prefix`.
---
--- `word` carries the leading slash, because 'completefunc' replaces the text
--- from the reported start column: the start column points at "/", so the
--- replacement must include it or the slash would be eaten.
---
--- @param prefix? string text typed so far, with or without the leading "/"
--- @return table[] 'completefunc' items
function M.items(prefix)
  local needle = prefix or ''
  if needle:sub(1, 1) == '/' then
    needle = needle:sub(2)
  end
  needle = needle:lower()

  local result = {}
  for _, skill in ipairs(skills.list()) do
    local name = skill.name or ''
    if name ~= '' and name:lower():sub(1, #needle) == needle then
      local desc = skill.description or ''
      table.insert(result, {
        word = '/' .. name,
        abbr = '/' .. name,
        menu = desc ~= '' and M.truncate(desc) or nil,
        info = desc ~= '' and desc or nil,
        dup = 1,
        icase = 1,
      })
    end
  end
  return result
end

--- Build the candidate list for skill arguments, from `skill.complete`.
---
--- Vim does not filter the candidates of a custom 'completefunc', so the
--- prefix match happens here.
---
--- @param ctx table context returned by M.context
--- @param base string text typed so far
--- @return table[] 'completefunc' items
function M.arg_items(ctx, base)
  local ok, words = pcall(ctx.skill.complete, base)
  if not ok or type(words) ~= 'table' then
    return {}
  end

  local needle = (base or ''):lower()
  local result = {}
  for _, word in ipairs(words) do
    if type(word) == 'string'
      and word ~= ''
      and word:lower():sub(1, #needle) == needle
    then
      table.insert(result, { word = word, abbr = word, dup = 1, icase = 1 })
    end
  end
  return result
end

--- 'completefunc' entry point for the prompt buffer.
--- @param findstart integer 1 while locating the start column, 0 when asked for matches
--- @param base string text between the reported start column and the cursor
--- @return integer|table start column, -3 (cancel), or the candidate list
function M.completefunc(findstart, base)
  local ok, result = pcall(function()
    local line = vim.api.nvim_get_current_line()
    local col = vim.api.nvim_win_get_cursor(0)[2]
    local ctx = M.context(line, col)

    if findstart == 1 then
      return ctx and ctx.start or -3
    end

    if not ctx then
      return {}
    end
    if ctx.kind == 'args' then
      return M.arg_items(ctx, base or ctx.base)
    end
    return M.items(base or ctx.base)
  end)

  if not ok then
    -- Never let a completion error reach insert mode: cancel the round.
    return findstart == 1 and -3 or {}
  end
  return result
end

--- Define the global Vimscript wrapper, once per session.
--- @return nil
local function define_vim_function()
  if vim.fn.exists('*' .. M.VIM_FUNC_NAME) == 1 then
    return
  end
  vim.cmd(([[
function! %s(findstart, base) abort
  return luaeval("require('chat.windows.complete').completefunc(_A[1], _A[2])", [a:findstart, a:base])
endfunction
]]):format(M.VIM_FUNC_NAME))
end

--- The Vimscript 'completefunc' expression for the prompt buffer.
--- @return string
function M.option_value()
  define_vim_function()
  return M.VIM_FUNC_NAME
end

return M

