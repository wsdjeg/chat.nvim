-- Session storage: cache read/write and iteration
local M = {}

local log = require('chat.log')

M.cache_dir = vim.fn.stdpath('cache') .. '/chat.nvim/'

local function get_config_system_prompt()
  local config = require('chat.config')
  local prompt = config.config.system_prompt

  if type(prompt) == 'function' then
    local ok, result = pcall(prompt)
    if ok then
      if type(result) == 'string' then
        return result
      else
        log.warn(
          'system_prompt function should return string, got ' .. type(result)
        )
        return tostring(result or '')
      end
    else
      log.warn(
        string.format('Failed to call system_prompt function: %s', result)
      )
      return ''
    end
  end

  return prompt or ''
end

--- @type table<string, ChatSession>
M.sessions = {}

function M.write_cache(session_id)
  if not M.sessions[session_id] then
    log.error('session does not existed, skip writing cache.')
    return false
  end
  if vim.fn.isdirectory(M.cache_dir) == 0 then
    local ok, err = pcall(vim.fn.mkdir, M.cache_dir, 'p')
    if not ok then
      log.warn('failed to created cache directory, ' .. err)
      return
    end
  end
  local f_name = M.cache_dir .. session_id .. '.json'
  local file = io.open(f_name, 'w')
  if not file then
    log.error('Failed to open cache file: ' .. f_name)
    return false
  end
  local success, err = pcall(function()
    file:write(vim.json.encode(M.sessions[session_id]))
    io.close(file)
  end)
  if not success then
    log.error('Failed to write cache: ' .. err)
    return false
  end

  return true
end

---@param session_id string
---@return string|nil
function M.get_cache_path(session_id)
  if M.sessions[session_id] then
    local f_name = M.cache_dir .. session_id .. '.json'
    local stat = vim.uv.fs_stat(f_name)
    if stat then
      return f_name
    end
  end
end

function M.iter_sessions()
  if vim.fn.isdirectory(M.cache_dir) == 0 then
    return coroutine.wrap(function() end)
  end

  local files = vim.fn.globpath(M.cache_dir, '*.json', false, true)
  local index = 0
  local count = #files

  return coroutine.wrap(function()
    while index < count do
      index = index + 1
      local filepath = files[index]
      local session_id = vim.fn.fnamemodify(filepath, ':t:r')

      if M.sessions[session_id] then
        coroutine.yield(session_id, M.sessions[session_id])
      else
        local file = io.open(filepath, 'r')
        if file then
          local content = file:read('*a')
          io.close(file)
          local ok, obj = pcall(vim.json.decode, content)
          if ok and obj ~= vim.NIL then
            local need_save = false

            -- Compatibility: old version without id field
            if not obj.id then
              obj.id = session_id
              obj = {
                id = obj.id,
                messages = obj,
                provider = require('chat.config').config.provider,
                model = require('chat.config').config.model,
                cwd = vim.fn.getcwd(),
              }
              need_save = true
            end

            -- Compatibility: old version without cwd field
            if not obj.cwd then
              obj.cwd = vim.fn.getcwd()
              need_save = true
            end

            -- Compatibility: old version without prompt field
            if not obj.prompt then
              obj.prompt = get_config_system_prompt()
              need_save = true
            end

            M.sessions[obj.id] = obj
            if need_save then
              M.write_cache(obj.id)
            end
            coroutine.yield(obj.id, obj)
          end
        end
      end
    end
  end)
end

return M

