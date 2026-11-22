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
-- Between the two calls Vim *removes* the text it is completing from the
-- buffer, so by the second call the line no longer holds the token: typing
-- "/gr" and completing leaves an empty line with the cursor at column 0.
-- The context therefore has to be captured during the findstart phase and
-- reused; recomputing it from the buffer in the second phase always yields
-- nil and silently cancels the round (no popup at all). `M.context` stays the
-- pure, buffer-independent helper used by both phases and by the tests.
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
--
-- Debugging: a round that never starts is invisible from the outside, because
-- the only symptom is "the popup does not appear". `M.set_debug(true)` turns
-- on tracing for the whole path:
--
--   M.diag()      buffer/option state that decides whether a round can start
--   M.attach(buf) insert-mode autocmds bracketing the keystroke
--   M.stamp(tag)  every phase of 'completefunc', with the candidate summary
--
-- Trace lines go to the runtime log (debug level) *and* to
-- `{storage_dir}/complete-trace.log`, because the logger may be configured to
-- drop debug lines - which is exactly the situation being debugged. The file
-- is truncated when tracing is enabled.

local M = {}

local config = require('chat.config')
local skills = require('chat.skills')
local log = require('chat.log')

-- Name of the global Vimscript wrapper used as 'completefunc'.
M.VIM_FUNC_NAME = 'ChatNvimSkillComplete'

-- Skill descriptions are one-liners; the popup menu is one line as well.
M.MENU_WIDTH = 48

-- Trace file name under `storage_dir`.
M.TRACE_FILE_NAME = 'complete-trace.log'

-- Tracing switch. Off by default: a trace line would otherwise be written on
-- every keystroke-driven completion round.
M.debug = false

-- Context captured during the findstart phase, keyed by buffer handle.
--
-- The second 'completefunc' call cannot recompute it, because Vim has already
-- deleted the completed text from the buffer by then.
local pending = {}

--- Render varargs as one log line. Tables are inspected and flattened.
--- @param ... any
--- @return string
local function fmt(...)
  local parts = {}
  for _, v in ipairs({ ... }) do
    if type(v) == 'table' then
      table.insert(parts, (vim.inspect(v):gsub('[\r\n]+', ' ')))
    else
      table.insert(parts, tostring(v))
    end
  end
  return table.concat(parts, ' ')
end

--- Absolute path of the trace file.
--- @return string
function M.trace_path()
  local dir = (config.config and config.config.storage_dir)
    or (vim.fn.stdpath('data') .. '/chat.nvim/')
  return dir .. M.TRACE_FILE_NAME
end

--- Append one raw line to the trace file, creating the directory if needed.
--- @param line string
--- @return nil
local function write_trace(line)
  local path = M.trace_path()
  pcall(vim.fn.mkdir, vim.fn.fnamemodify(path, ':h'), 'p')
  local fd = io.open(path, 'a')
  if not fd then
    return
  end
  fd:write(line, '\n')
  fd:close()
end

--- Log one trace line. A no-op unless `M.debug` is on.
---
--- Writes to the runtime log (debug level) and to the trace file, so the line
--- survives a logger that filters debug output.
---
--- @param tag string short event name, e.g. 'enter'
--- @param ... any extra fields appended to the line
--- @return nil
function M.stamp(tag, ...)
  if not M.debug then
    return
  end
  local extra = select('#', ...) > 0 and (' ' .. fmt(...)) or ''
  local line = '[complete] ' .. tag .. extra
  log.debug(line)
  write_trace(('[%s] '):format(os.date('%H:%M:%S')) .. line)
end

--- Turn completion tracing on or off at runtime.
---
--- Enabling truncates the trace file and starts it with the current `M.diag()`
--- dump, so the log always begins with the state that decided the round.
---
--- @param on boolean
--- @return boolean the new state
function M.set_debug(on)
  M.debug = not not on
  if M.debug then
    local path = M.trace_path()
    local fd = io.open(path, 'w')
    if fd then
      fd:write(('[%s] [complete] trace start\n'):format(os.date('%H:%M:%S')))
      fd:close()
    end
    M.stamp('debug', 'enabled')
    for k, v in pairs(M.diag()) do
      M.stamp('diag', k .. '=', v)
    end
    M.stamp('hint', 'trace file: ' .. path)
  else
    M.stamp('debug', 'disabled')
  end
  return M.debug
end

--- Compact one-line summary of a candidate list, for the 'return-items' trace.
--- @param items table[]|any 'completefunc' result
--- @return string
local function summarize(items)
  if type(items) ~= 'table' then
    return tostring(items)
  end
  local words = {}
  for i, item in ipairs(items) do
    if i > 10 then
      table.insert(words, '…')
      break
    end
    table.insert(
      words,
      type(item) == 'table' and (item.word or '?') or tostring(item)
    )
  end
  return string.format('%d [%s]', #items, table.concat(words, ' '))
end

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
--- Pure function of `line`/`col`: it never reads the buffer, so it is still
--- usable from the second phase when the buffer text is already gone.
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
    M.stamp('skill-complete-failed', 'skill=' .. tostring(ctx.skill.name), fmt(words))
    return {}
  end

  local needle = (base or ''):lower()
  local result = {}
  for _, word in ipairs(words) do
    if
      type(word) == 'string'
      and word ~= ''
      and word:lower():sub(1, #needle) == needle
    then
      table.insert(result, { word = word, abbr = word, dup = 1, icase = 1 })
    end
  end
  return result
end

--- Capture the context for the current buffer and remember it for phase two.
---
--- Returning nil cancels the round, and forgetting the cached entry keeps a
--- later second-phase call from reusing a stale context.
---
--- @param buf integer buffer handle
--- @return table|nil ctx
local function capture(buf)
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2]
  local ctx = M.context(line, col)
  M.stamp(
    'context',
    'findstart=1',
    'line=' .. fmt(line),
    'col=' .. col,
    'ctx=' .. fmt(ctx)
  )
  if ctx then
    pending[buf] = ctx
  else
    pending[buf] = nil
  end
  return ctx
end

--- 'completefunc' entry point for the prompt buffer.
--- @param findstart integer 1 while locating the start column, 0 when asked for matches
--- @param base string text between the reported start column and the cursor
--- @return integer|table start column, -3 (cancel), or the candidate list
function M.completefunc(findstart, base)
  -- Traced end to end: enter -> context -> (return-start | return-items | error).
  M.stamp('enter', 'findstart=' .. tostring(findstart), 'base=' .. fmt(base))

  local buf = vim.api.nvim_get_current_buf()

  local ok, result = pcall(function()
    if findstart == 1 then
      local ctx = capture(buf)
      return ctx and ctx.start or -3
    end

    -- The buffer no longer holds the completed token, so reuse the context
    -- captured in the findstart phase. Fall back to the buffer only when the
    -- function is driven directly (tests, manual `:call`) without a
    -- preceding findstart call.
    local ctx = pending[buf]
    pending[buf] = nil
    if not ctx then
      ctx = capture(buf)
      if ctx then
        pending[buf] = nil
      end
    else
      M.stamp('context', 'findstart=0', 'cached', 'ctx=' .. fmt(ctx))
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
    pending[buf] = nil
    M.stamp('error', fmt(result))
    return findstart == 1 and -3 or {}
  end

  if findstart == 1 then
    M.stamp('return-start', 'start=' .. tostring(result))
  else
    M.stamp('return-items', summarize(result))
  end
  return result
end

--- Drop the cached context for a buffer.
---
--- Called when a prompt buffer is wiped, so the table cannot grow with one
--- stale entry per closed prompt.
---
--- @param buf integer buffer handle
--- @return nil
function M.forget(buf)
  pending[buf] = nil
end

--- Dump the editor/buffer state that decides whether CTRL-X CTRL-U can start a
--- round at all. Call it from inside the prompt window, in insert mode.
--- @return table<string, any>
function M.diag()
  local buf = vim.api.nvim_get_current_buf()
  local mode = vim.api.nvim_get_mode().mode
  return {
    mode = mode,
    insert_mode = mode:sub(1, 1) == 'i',
    buf = buf,
    win = vim.api.nvim_get_current_win(),
    buftype = vim.api.nvim_get_option_value('buftype', { buf = buf }),
    modifiable = vim.api.nvim_get_option_value('modifiable', { buf = buf }),
    completefunc = vim.api.nvim_get_option_value('completefunc', { buf = buf }),
    omnifunc = vim.api.nvim_get_option_value('omnifunc', { buf = buf }),
    completeopt = vim.api.nvim_get_option_value('completeopt', { buf = buf }),
    -- An insert-mode mapping on <C-x> or <C-u> would swallow the submode.
    map_C_x = vim.fn.maparg('<C-x>', 'i', false, true),
    map_C_u = vim.fn.maparg('<C-u>', 'i', false, true),
    wrapper_exists = vim.fn.exists('*' .. M.VIM_FUNC_NAME),
    tracing = M.debug,
  }
end

--- Print `M.diag()` into the message area.
--- @return table<string, any> the dumped table
function M.diag_print()
  local d = M.diag()
  print(vim.inspect(d))
  return d
end

--- Install tracing autocmds on a prompt buffer.
---
--- 'completefunc' is only reached after Vim decides a round may start, so a
--- silent no-op means the call never happened. These events bracket the
--- keystroke and make that visible:
---
---   InsertEnter     -> insert mode entered, keys can reach completion
---   TextChangedI    -> the typed text actually changed
---   CompleteChanged -> a round started and the popup was updated
---   CompleteDone    -> the round ended (accepted, cancelled or rejected)
---   ModeChanged     -> mode transitions around the round
---
--- Every callback is a `M.stamp` that returns immediately unless `M.debug` is
--- on, so the autocmds cost nothing in normal use.
---
--- @param buf integer prompt buffer handle
--- @return nil
function M.attach(buf)
  local group = vim.api.nvim_create_augroup(
    'chat_nvim_complete_trace_' .. tostring(buf),
    { clear = true }
  )
  vim.api.nvim_create_autocmd({
    'InsertEnter',
    'InsertLeave',
    'TextChangedI',
    'CompleteChanged',
    'CompleteDone',
    'ModeChanged',
    'WinEnter',
    'BufEnter',
  }, {
    group = group,
    buffer = buf,
    callback = function(args)
      M.stamp(
        'autocmd:' .. args.event,
        'mode=' .. vim.api.nvim_get_mode().mode,
        'buf=' .. args.buf,
        'line=' .. fmt(vim.api.nvim_get_current_line())
      )
    end,
  })

  M.stamp(
    'attach',
    'buf=' .. tostring(buf),
    'completefunc=' .. vim.api.nvim_get_option_value('completefunc', { buf = buf }),
    'tracing=' .. tostring(M.debug)
  )
end

--- Define the global Vimscript wrapper, once per session.
--- @return nil
local function define_vim_function()
  if vim.fn.exists('*' .. M.VIM_FUNC_NAME) == 1 then
    M.stamp('wrapper', 'already defined: ' .. M.VIM_FUNC_NAME)
    return
  end
  vim.cmd(([[
function! %s(findstart, base) abort
  return luaeval("require('chat.windows.complete').completefunc(_A[1], _A[2])", [a:findstart, a:base])
endfunction
]]):format(M.VIM_FUNC_NAME))
  M.stamp('wrapper', 'defined: ' .. M.VIM_FUNC_NAME)
end

--- The Vimscript 'completefunc' expression for the prompt buffer.
--- @return string
function M.option_value()
  define_vim_function()
  return M.VIM_FUNC_NAME
end

return M

