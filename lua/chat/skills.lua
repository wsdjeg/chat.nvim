-- lua/chat/skills.lua
-- Skill system: slash commands in the prompt window
--
-- Users type /name [args] in the prompt window to invoke skills.
-- Built-in skills: /clear /new /delete /model /provider /cwd /pin /title /retry /help
-- User skills can be registered via config or require('chat').register_skill()

local M = {}

local log = require('chat.log')

---@type table<string, ChatSkill>
local registry = {}

---@class ChatSkillContext
---@field session string Current session ID

---@class ChatSkill
---@field name string Unique identifier (used as /name)
---@field description string Short description shown in /help
---@field handler fun(args: string, ctx: ChatSkillContext) Handler function
---@field complete? fun(args: string): string[] Optional completion function
---@field builtin? boolean True for built-in skills

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
--- @return boolean True if skill was found and dispatched
function M.dispatch(input, session)
  local name, args = M.parse(input)
  if not name or #name == 0 then
    return false
  end

  local skill = registry[name]
  if not skill then
    log.notify('Unknown skill: /' .. name, 'WarningMsg')
    return false
  end

  local ctx = {
    session = session,
  }

  local ok, err = pcall(skill.handler, args, ctx)
  if not ok then
    log.error('[Skills] handler error for /' .. name .. ': ' .. tostring(err))
    log.notify('Skill /' .. name .. ' failed: ' .. tostring(err), 'ErrorMsg')
  end

  return true
end

-- ─── Built-in skills ──────────────────────────────────────────

--- /clear — Clear all messages in current session
M._builtin_clear = {
  name = 'clear',
  description = 'Clear all messages in current session',
  builtin = true,
  handler = function(_, ctx)
    local sessions = require('chat.sessions')
    local windows = require('chat.windows')
    if sessions.clear(ctx.session) then
      windows.render_result_buf()
      windows.set_result_win_title(' chat.nvim ')
      log.notify('Session cleared')
    end
  end,
}

--- /new — Create a new session
M._builtin_new = {
  name = 'new',
  description = 'Create a new session',
  builtin = true,
  handler = function(_, _)
    local sessions = require('chat.sessions')
    local windows = require('chat.windows')
    local new_id = sessions.new()
    windows.open({ session = new_id })
  end,
}

--- /delete — Delete current session
M._builtin_delete = {
  name = 'delete',
  description = 'Delete current session',
  builtin = true,
  handler = function(_, ctx)
    local sessions = require('chat.sessions')
    local windows = require('chat.windows')
    local next_id = sessions.delete(ctx.session)
    if next_id then
      windows.open({ session = next_id })
    end
  end,
}

--- /model [name] — Switch model
M._builtin_model = {
  name = 'model',
  description = 'Switch model (e.g. /model gpt-4o)',
  builtin = true,
  handler = function(args, ctx)
    local sessions = require('chat.sessions')

    if args and #args > 0 then
      sessions.set_session_model(ctx.session, args)
      log.notify('Model: ' .. args)
      return
    end

    -- No args: show selection UI
    local provider_name = sessions.get_session_provider(ctx.session)
    local ok, provider = pcall(require, 'chat.providers.' .. provider_name)
    local models = {}
    if ok and provider.available_models then
      models = provider.available_models()
    end

    if #models == 0 then
      log.notify('No models available for provider: ' .. provider_name, 'WarningMsg')
      return
    end

    vim.ui.select(models, {
      prompt = 'Select model: ',
    }, function(choice)
      if choice then
        sessions.set_session_model(ctx.session, choice)
        log.notify('Model: ' .. choice)
      end
    end)
  end,
}

--- /provider [name] — Switch provider
M._builtin_provider = {
  name = 'provider',
  description = 'Switch provider (e.g. /provider openai)',
  builtin = true,
  handler = function(args, ctx)
    local sessions = require('chat.sessions')
    local windows = require('chat.windows')

    if args and #args > 0 then
      sessions.set_session_provider(ctx.session, args)
      windows.redraw_title()
      log.notify('Provider: ' .. args)
      return
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
        sessions.set_session_provider(ctx.session, choice)
        -- Try to set first available model
        local ok, provider = pcall(require, 'chat.providers.' .. choice)
        if ok and provider.available_models then
          local models = provider.available_models()
          if #models > 0 then
            sessions.set_session_model(ctx.session, models[1])
          end
        end
        windows.redraw_title()
        log.notify('Provider: ' .. choice)
      end
    end)
  end,
}

--- /cwd <path> — Change working directory
M._builtin_cwd = {
  name = 'cwd',
  description = 'Change working directory (e.g. /cwd /tmp)',
  builtin = true,
  handler = function(args, ctx)
    local sessions = require('chat.sessions')
    local windows = require('chat.windows')

    if args and #args > 0 then
      local dir = vim.fs.normalize(vim.fn.fnamemodify(args, ':p'))
      if vim.fn.isdirectory(dir) == 1 then
        sessions.change_cwd(ctx.session, dir)
        windows.redraw_title()
        log.notify('CWD: ' .. dir)
      else
        log.notify('Not a valid directory: ' .. dir, 'WarningMsg')
      end
    else
      log.notify('Usage: /cwd <directory>', 'WarningMsg')
    end
  end,
}

--- /pin — Toggle pin status
M._builtin_pin = {
  name = 'pin',
  description = 'Toggle pin status of current session',
  builtin = true,
  handler = function(_, ctx)
    local sessions = require('chat.sessions')
    local current = sessions.get_session_pin(ctx.session)
    sessions.set_session_pin(ctx.session, not current)
    require('chat.sessions.storage').write_cache(ctx.session)
    log.notify(current and 'Unpinned' or 'Pinned')
  end,
}

--- /title [text] — Set session title
M._builtin_title = {
  name = 'title',
  description = 'Set session title (e.g. /title My Chat)',
  builtin = true,
  handler = function(args, ctx)
    local sessions = require('chat.sessions')
    local windows = require('chat.windows')

    if args and #args > 0 then
      sessions.set_session_title(ctx.session, args)
      windows.redraw_title()
      log.notify('Title: ' .. args)
    else
      -- No args: use vim.ui.input
      local old_title = sessions.get_session_title(ctx.session) or ''
      vim.ui.input({
        prompt = 'Session title: ',
        default = old_title,
      }, function(input)
        if input and #input > 0 then
          sessions.set_session_title(ctx.session, input)
          windows.redraw_title()
        end
      end)
    end
  end,
}

--- /retry — Retry last request
M._builtin_retry = {
  name = 'retry',
  description = 'Retry last request',
  builtin = true,
  handler = function(_, ctx)
    local sessions = require('chat.sessions')
    local jobid = sessions.retry(ctx.session)
    if jobid and jobid > 0 then
      require('chat.spinners').start()
      log.notify('Retrying...')
    else
      log.notify('Nothing to retry', 'WarningMsg')
    end
  end,
}

--- /help — List all available skills
M._builtin_help = {
  name = 'help',
  description = 'Show available skills',
  builtin = true,
  handler = function(_, _)
    local skills = M.list()
    local lines = { 'Available skills:', '' }
    for _, skill in ipairs(skills) do
      local tag = skill.builtin and '' or '(user) '
      table.insert(
        lines,
        string.format('  /%s %s- %s', skill.name, tag, skill.description)
      )
    end
    table.insert(lines, '')
    table.insert(lines, 'Type /name in the prompt window to use a skill.')
    log.notify(lines)
  end,
}

--- Initialize built-in skills
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
end

return M

