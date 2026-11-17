-- lua/chat/skills.lua
-- Skill system: slash commands in the prompt window
--
-- Users type /name [args] in the prompt window to invoke skills.
-- Built-in skills: /clear /new /delete /model /provider /cwd /pin /title /retry /help
-- User skills can be registered via config or require('chat').register_skill()
--
-- Output contract (single channel per skill, never both):
--
--   content-type  -> `return` a string / ChatSkillResult
--                    windows.dispatch_skill appends it to the session and
--                    renders it, and integrations are notified. Used for
--                    content the model should see later (/help, error texts,
--                    injected prompts).
--
--   state-type    -> `return M.notify(ctx, ...)`
--                    A state change (/model, /cwd, /pin, /title, /retry)
--                    needs a short receipt, but appending an assistant
--                    message would pollute the LLM history and push the
--                    receipt to IM platforms.
--
-- `M.notify` routes that receipt by ctx.origin:
--
--   local          -> log.notify (transient popup), returns nil, so nothing
--                     is appended to the session (unchanged behaviour).
--   http/...       -> returns the text instead, which dispatch_skill appends
--                     as an assistant message the remote caller can read via
--                     GET /session/:id/messages. A desktop popup is invisible
--                     to that caller, so none is emitted.
--
-- Skills that need the Neovim UI (vim.ui.select / vim.ui.input) or that would
-- switch the local window must check ctx.origin: a remote caller cannot
-- answer a desktop prompt and must not hijack the desktop's window. They
-- return a usage string instead.
--
-- Doing both channels makes the same text show up twice (transient popup +
-- session message), which is the bug this contract exists to prevent.

local M = {}

local log = require('chat.log')

---@type table<string, ChatSkill>
local registry = {}

---@class ChatSkillContext
---@field session string Current session ID
---@field origin 'local'|'http'|'integration'|'scheduler' Who invoked the skill

---@class ChatSkillResult
---@field content string Message content to append to the session
---@field role? '"user"'|'"assistant"' Message role (default: 'assistant')
---@field request? boolean If true, trigger LLM request after appending (default: false)

---@class ChatSkill
---@field name string Unique identifier (used as /name)
---@field description string Short description shown in /help
---@field handler fun(args: string, ctx: ChatSkillContext): string|ChatSkillResult|nil Handler function
---@field complete? fun(args: string): string[] Optional completion function
---@field builtin? boolean True for built-in skills

--- True when the invocation came from the local prompt window.
--- A missing origin means "direct call without dispatch()" (tests, scripts),
--- which behaves like the local prompt.
--- @param ctx ChatSkillContext|nil
--- @return boolean
local function is_local(ctx)
  return (ctx and ctx.origin or 'local') == 'local'
end

--- Emit a receipt for a state-type skill, routed by ctx.origin.
---
--- Local invocations get a transient popup and nil is returned, so nothing
--- lands in the session history (unchanged behaviour). Remote invocations get
--- the text back instead, which dispatch_skill appends as an assistant
--- message: a desktop popup is invisible to an HTTP caller, so none is shown.
--
--- Routing happens here rather than through a callback injected by dispatch()
--- so that calling a handler directly (tests, scripts) behaves the same as
--- going through the dispatch path.
--- @param ctx ChatSkillContext|nil
--- @param msg string|string[] Receipt text
--- @param color? string Highlight group for the local popup
--- @return string|nil Receipt text for remote callers, nil for local ones
function M.notify(ctx, msg, color)
  if is_local(ctx) then
    log.notify(msg, color)
    return nil
  end
  -- Returning a table would be misread as a ChatSkillResult, so flatten.
  if type(msg) == 'table' then
    return table.concat(msg, '\n')
  end
  return msg
end

--- Register a skill
--- @param skill ChatSkill
--- @return boolean True if registered successfully
function M.register(skill)
  if not skill or type(skill) ~= 'table' then
    log.error('[Skills] register: skill must be a table')
    return false
  end
  if type(skill.name) ~= 'string' or #skill.name == 0 then
    log.error('[Skills] register: skill.name must be a non-empty string')
    return false
  end
  if type(skill.handler) ~= 'function' then
    log.error('[Skills] register: skill.handler must be a function')
    return false
  end
  if type(skill.description) ~= 'string' then
    skill.description = ''
  end

  registry[skill.name] = skill
  return true
end

--- Unregister a skill by name
--- @param name string Skill name
function M.unregister(name)
  registry[name] = nil
end

--- Get a skill by name
--- @param name string
--- @return ChatSkill|nil
function M.get(name)
  return registry[name]
end

--- List all registered skills, sorted by name
--- @return ChatSkill[]
function M.list()
  local result = {}
  for _, skill in pairs(registry) do
    table.insert(result, skill)
  end
  table.sort(result, function(a, b)
    return a.name < b.name
  end)
  return result
end

--- Parse input string into skill name and args
--- @param input string Raw input starting with /
--- @return string|nil name, string args
function M.parse(input)
  if not input or input:sub(1, 1) ~= '/' then
    return nil, ''
  end

  local rest = input:sub(2)
  -- Find first space to separate name from args
  local space_idx = rest:find(' ')
  if space_idx then
    return rest:sub(1, space_idx - 1), vim.trim(rest:sub(space_idx + 1))
  else
    return rest, ''
  end
end

--- Dispatch a skill invocation
--- @param input string Raw input starting with /
--- @param session string Current session ID
--- @param origin? 'local'|'http'|'integration'|'scheduler' Who invoked it
--- @return string|table|nil|false Returns output string, ChatSkillResult table, nil (no output), or false (not a skill)
function M.dispatch(input, session, origin)
  local name, args = M.parse(input)
  if not name or #name == 0 then
    return false
  end

  local skill = registry[name]
  if not skill then
    -- Content channel only: the caller appends this to the session, which is
    -- already visible in the result window. Notifying as well would duplicate.
    return 'Unknown skill: /' .. name
  end

  local ctx = {
    session = session,
    -- Who invoked the skill. Skills that need a Neovim UI (vim.ui.select,
    -- vim.ui.input) or that switch the local window must know whether the
    -- request came from the local prompt or from a remote client.
    origin = origin or 'local',
  }

  local ok, result = pcall(skill.handler, args, ctx)
  if not ok then
    local msg = 'Skill /' .. name .. ' failed: ' .. tostring(result)
    pcall(log.error, '[Skills] handler error for /' .. name .. ': ' .. tostring(result))
    -- Content channel only, same reason as the unknown-skill branch above.
    return msg
  end

  return result
end

-- ─── Built-in skills ──────────────────────────────────────────

--- /clear - Clear all messages in current session
M._builtin_clear = {
  name = 'clear',
  description = 'Clear all messages in current session',
  builtin = true,
  handler = function(_, ctx)
    local sessions = require('chat.sessions')
    local windows = require('chat.windows')
    if sessions.is_in_progress(ctx.session) then
      return M.notify(ctx, 'Request in progress.', 'WarningMsg')
    end

    if not sessions.clear(ctx.session) then
      return
    end

    -- The result buffer only ever shows the local current session: clearing
    -- another session remotely must not repaint the desktop window.
    if ctx.session == windows.current_session() then
      windows.render_result_buf()
      windows.set_result_win_title(' chat.nvim ', ctx.session)
    end

    return M.notify(ctx, 'Session cleared')
  end,
}

--- /new - Create a new session
M._builtin_new = {
  name = 'new',
  description = 'Create a new session',
  builtin = true,
  handler = function(_, ctx)
    local sessions = require('chat.sessions')
    local windows = require('chat.windows')
    local new_id, err = sessions.new()
    if not new_id then
      return M.notify(ctx, err or '创建会话失败', 'ErrorMsg')
    end

    if is_local(ctx) then
      windows.open({ session = new_id })
    end

    -- Remote: the receipt carries the id, appended to the session that asked
    -- for it. Switching the desktop window is a local UI action.
    return M.notify(ctx, 'New session: ' .. new_id)
  end,
}

--- /delete - Delete current session
M._builtin_delete = {
  name = 'delete',
  description = 'Delete current session',
  builtin = true,
  handler = function(_, ctx)
    local sessions = require('chat.sessions')
    local windows = require('chat.windows')
    if sessions.is_in_progress(ctx.session) then
      return M.notify(ctx, 'Request in progress.', 'WarningMsg')
    end

    local next_id = sessions.delete(ctx.session)
    if next_id and is_local(ctx) then
      windows.open({ session = next_id })
    end

    -- dispatch_skill drops the output for a session that no longer exists, so
    -- this receipt only reaches the local popup in practice.
    return M.notify(
      ctx,
      next_id and ('Session deleted, switched to: ' .. next_id)
        or 'Session deleted'
    )
  end,
}

--- /model [name] - Switch model
M._builtin_model = {
  name = 'model',
  description = 'Switch model (e.g. /model gpt-4o)',
  builtin = true,
  handler = function(args, ctx)
    local sessions = require('chat.sessions')
    local windows = require('chat.windows')

    if sessions.is_in_progress(ctx.session) then
      return M.notify(ctx, 'Request in progress.', 'WarningMsg')
    end

    --- @param value string new model name
    local function apply_model(value)
      sessions.set_session_model(ctx.session, value)
      -- The provider/model pill lives in the prompt window title only.
      -- Passing the session keeps a remote change from repainting the title
      -- of whichever session the desktop happens to show.
      windows.redraw_title(ctx.session)
      return M.notify(ctx, 'Model: ' .. value)
    end

    if args and #args > 0 then
      return apply_model(args)
    end

    if not is_local(ctx) then
      return 'Usage: /model <name> (interactive selection needs the Neovim UI)'
    end

    -- No args: show selection UI
    local provider_name = sessions.get_session_provider(ctx.session)
    local ok, provider = pcall(require, 'chat.providers.' .. provider_name)
    local models = {}
    if ok and provider.available_models then
      models = provider.available_models()
    end

    if #models == 0 then
      return M.notify(
        ctx,
        'No models available for provider: ' .. provider_name,
        'WarningMsg'
      )
    end

    vim.ui.select(models, {
      prompt = 'Select model: ',
    }, function(choice)
      if choice then
        apply_model(choice)
      end
    end)
  end,
}

--- /provider [name] - Switch provider
M._builtin_provider = {
  name = 'provider',
  description = 'Switch provider (e.g. /provider openai)',
  builtin = true,
  handler = function(args, ctx)
    local sessions = require('chat.sessions')
    local windows = require('chat.windows')

    if sessions.is_in_progress(ctx.session) then
      return M.notify(ctx, 'Request in progress.', 'WarningMsg')
    end

    --- @param name string provider module name
    local function apply_provider(name)
      sessions.set_session_provider(ctx.session, name)
      -- Try to set first available model
      local ok, provider = pcall(require, 'chat.providers.' .. name)
      if ok and provider.available_models then
        local models = provider.available_models()
        if #models > 0 then
          sessions.set_session_model(ctx.session, models[1])
        end
      end
      windows.redraw_title(ctx.session)
      return M.notify(ctx, 'Provider: ' .. name)
    end

    if args and #args > 0 then
      return apply_provider(args)
    end

    if not is_local(ctx) then
      return 'Usage: /provider <name> (interactive selection needs the Neovim UI)'
    end

    -- No args: show selection UI
    local files = vim.api.nvim_get_runtime_file('lua/chat/providers/*.lua', true)
    local providers = {}
    for _, f in ipairs(files) do
      local name = vim.fn.fnamemodify(f, ':t:r')
      table.insert(providers, name)
    end
    table.sort(providers)

    vim.ui.select(providers, {
      prompt = 'Select provider: ',
    }, function(choice)
      if choice then
        apply_provider(choice)
      end
    end)
  end,
}

--- /cwd <path> - Change working directory
M._builtin_cwd = {
  name = 'cwd',
  description = 'Change working directory (e.g. /cwd /tmp)',
  builtin = true,
  handler = function(args, ctx)
    local sessions = require('chat.sessions')
    local windows = require('chat.windows')

    if sessions.is_in_progress(ctx.session) then
      return M.notify(ctx, 'Request in progress.', 'WarningMsg')
    end

    if not args or #args == 0 then
      return M.notify(ctx, 'Usage: /cwd <directory>', 'WarningMsg')
    end

    -- Resolve relative paths against the session cwd instead of the editor
    -- cwd, so `/cwd ../foo` walks up from where this session actually works.
    local util = require('chat.util')
    local base = sessions.getcwd(ctx.session) or vim.fn.getcwd()
    local dir = util.resolve(vim.fn.expand(args), base)
    if not dir or vim.fn.isdirectory(dir) ~= 1 then
      return M.notify(
        ctx,
        'Not a valid directory: ' .. (dir or args),
        'WarningMsg'
      )
    end

    sessions.change_cwd(ctx.session, dir)
    -- cwd is rendered as a pill in the prompt window title.
    windows.redraw_title(ctx.session)
    return M.notify(ctx, 'CWD: ' .. dir)
  end,
}

--- /pin - Toggle pin status
M._builtin_pin = {
  name = 'pin',
  description = 'Toggle pin status of current session',
  builtin = true,
  handler = function(_, ctx)
    local sessions = require('chat.sessions')
    local current = sessions.get_session_pin(ctx.session)
    sessions.set_session_pin(ctx.session, not current)
    require('chat.sessions.storage').write_cache(ctx.session)
    return M.notify(ctx, current and 'Unpinned' or 'Pinned')
  end,
}

--- /title [text] - Set session title
M._builtin_title = {
  name = 'title',
  description = 'Set session title (e.g. /title My Chat)',
  builtin = true,
  handler = function(args, ctx)
    local sessions = require('chat.sessions')
    local windows = require('chat.windows')

    --- The session title is the first pill of the *result* window title,
    --- while the prompt window only carries provider/model, cwd and
    --- integrations. Both titles therefore have to be rebuilt: redraw_title()
    --- alone leaves the result window showing the stale title.
    --- @param value string new session title
    local function apply_title(value)
      sessions.set_session_title(ctx.session, value)
      windows.redraw_title(ctx.session)
      windows.set_result_win_title(' chat.nvim ', ctx.session)
      return M.notify(ctx, 'Title: ' .. value)
    end

    if args and #args > 0 then
      return apply_title(args)
    end

    if not is_local(ctx) then
      return 'Usage: /title <text> (interactive input needs the Neovim UI)'
    end

    -- No args: use vim.ui.input
    local old_title = sessions.get_session_title(ctx.session) or ''
    vim.ui.input({
      prompt = 'Session title: ',
      default = old_title,
    }, function(input)
      if input and #input > 0 then
        apply_title(input)
      end
    end)
    -- nil: the input callback runs later and reports through its own receipt
  end,
}

--- /retry - Retry last request
M._builtin_retry = {
  name = 'retry',
  description = 'Retry last request',
  builtin = true,
  handler = function(_, ctx)
    local sessions = require('chat.sessions')
    if sessions.is_in_progress(ctx.session) then
      return M.notify(ctx, 'Request in progress.', 'WarningMsg')
    end

    local jobid = sessions.retry(ctx.session)
    if not (jobid and jobid > 0) then
      return M.notify(ctx, 'Nothing to retry', 'WarningMsg')
    end

    -- The spinner animates the local result window title only: a remote
    -- retry of another session has no local animation to drive.
    if is_local(ctx) then
      require('chat.spinners').start()
    end
    -- No request-triggering table return: the LLM call is already running,
    -- the client sees in_progress.
    return M.notify(ctx, 'Retrying...')
  end,
}

--- /help - List all available skills
M._builtin_help = {
  name = 'help',
  description = 'Show available skills',
  builtin = true,
  handler = function(_, _)
    local skills = M.list()
    local lines = { '## Available skills', '' }
    for _, skill in ipairs(skills) do
      local tag = skill.builtin and '' or ' (user)'
      table.insert(
        lines,
        string.format('- **/%s**%s - %s', skill.name, tag, skill.description)
      )
    end
    table.insert(lines, '')
    table.insert(lines, 'Type `/name` in the prompt window to use a skill.')
    -- Content channel only: the appended session message is the display.
    return table.concat(lines, '\n')
  end,
}

--- Auto-load user skills from lua/chat/skills/*.lua
--- Each file should return a ChatSkill table.
function M.autoload()
  local files = vim.api.nvim_get_runtime_file('lua/chat/skills/*.lua', true)
  for _, f in ipairs(files) do
    local name = vim.fn.fnamemodify(f, ':t:r')
    -- Skip README (documentation only, not a real skill)
    if name ~= 'README' then
      local module = 'chat.skills.' .. name
      local ok, skill = pcall(require, module)
      if ok and skill and type(skill) == 'table' then
        if type(skill.name) == 'string' and type(skill.handler) == 'function' then
          M.register(skill)
          log.debug('[Skills] autoloaded: /' .. skill.name .. ' from ' .. module)
        end
      elseif not ok then
        log.error('[Skills] failed to load ' .. module .. ': ' .. tostring(skill))
      end
    end
  end
end

--- Initialize built-in skills, then autoload user skills
function M.init()
  for _, key in ipairs({
    'clear',
    'new',
    'delete',
    'model',
    'provider',
    'cwd',
    'pin',
    'title',
    'retry',
    'help',
  }) do
    local skill = M['_builtin_' .. key]
    if skill then
      M.register(skill)
    end
  end

  M.autoload()
end

return M

