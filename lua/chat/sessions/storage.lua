---@class ChatMessageUsage
---@field total_tokens? integer
---@field prompt_tokens? integer
---@field completion_tokens? integer

---@class ChatMessage
---@field role string
---@field content string
---@field created integer
---@field usage? ChatMessageUsage
---@field reasoning_content? string
---@field tool_calls? table
---@field tool_call_id? string
---@field on_complete? boolean
---@field error? string
---@field tool_call_state? string

---@class ChatSession
---@field id string
---@field messages ChatMessage[]
---@field provider? string
---@field model? string
---@field cwd string session working directory
---@field prompt? string
---@field usage? ChatMessageUsage
---@field pin? boolean session pin status
---@field last_user_message_time? integer timestamp of the last user message
---@field cleared_at? integer timestamp when session was cleared
---@field deleted_at? integer timestamp when the session was moved to the trash

-- Session storage: cache read/write and iteration
local M = {}

local log = require('chat.log')
local config = require('chat.config')

M.cache_dir = config.config.storage_dir .. 'sessions/'

--- Directory holding deleted session cache files.
---
--- Kept as a sibling of `cache_dir` rather than a hidden sub-directory inside
--- it: `iter_sessions()` globs `cache_dir/*.json`, so anything below it would
--- be loaded back as an active session. As a sibling it is invisible to the
--- loader without extra filtering, and `set_cache_dir()` can derive it from
--- the test directory so the trash never touches the real data directory.
M.trash_dir = config.config.storage_dir .. 'sessions-trash/'

--- Derive the trash directory from a cache directory.
---
--- `set_cache_dir()` is the test hook: a temp `sessions/` path must come with
--- its own temp trash, otherwise deleting a session inside a test would write
--- into a directory shared by every test (or worse, the real storage dir).
--- Deriving from the cache directory itself keeps the pair together:
---
---   {storage_dir}/sessions/       -> {storage_dir}/sessions-trash/
---   /tmp/nvim.xxxx/sessions/      -> /tmp/nvim.xxxx/sessions-trash/
---   /tmp/nvim.xxxx/  (test)       -> /tmp/nvim.xxxx-trash/
---
--- The trailing slash is stripped first, so the suffix never produces
--- `sessions/-trash/`, which would land *inside* the cache directory and be
--- picked up again by `iter_sessions()`.
--- @param cache_dir string A `sessions/` directory path
--- @return string The matching trash directory path
local function derive_trash_dir(cache_dir)
  local normalized = vim.fs.normalize(cache_dir):gsub('/+$', '')
  return normalized .. '-trash/'
end

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

--- Sets a custom cache directory (for testing)
--- Resets in-memory sessions to avoid mixing with previous cache and derives
--- the matching trash directory, so tests never write into real storage
--- @param dir string The directory path to use for cache
function M.set_cache_dir(dir)
  M.cache_dir = dir
  M.trash_dir = derive_trash_dir(dir)
  M.sessions = {}
end

--- Writes session data to cache file in JSON format
--- Creates cache directory if it doesn't exist
--- @param session_id string The session identifier to write
--- @return boolean True if write succeeded, false otherwise
function M.write_cache(session_id)
  if not M.sessions[session_id] then
    log.warn('session does not exist, skipping cache write')
    return false
  end
  if vim.fn.isdirectory(M.cache_dir) == 0 then
    local ok, err = pcall(vim.fn.mkdir, M.cache_dir, 'p')
    if not ok then
      log.error('Failed to create cache directory: ' .. err)
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

--- Gets the file path for a session's cache file
--- Only returns a path if the session exists and the file is present
--- @param session_id string The session identifier
--- @return string|nil The cache file path if found, nil otherwise
function M.get_cache_path(session_id)
  if M.sessions[session_id] then
    local f_name = M.cache_dir .. session_id .. '.json'
    local stat = vim.uv.fs_stat(f_name)
    if stat then
      return f_name
    end
  end
end

--- Iterates over all cached sessions, loading them from disk if not already loaded
--- Handles backward compatibility for older cache formats
--- @return function A coroutine iterator that yields (session_id, session_data) pairs
--- @usage for session_id, session_data in storage.iter_sessions() do ... end
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
              obj = {
                id = session_id,
                messages = obj,
                provider = require('chat.config').config.provider,
                model = require('chat.config').config.model,
                cwd = vim.fs.normalize(vim.fn.getcwd()),
              }
              need_save = true
            end

            -- Compatibility: old version without cwd field
            if not obj.cwd then
              obj.cwd = vim.fs.normalize(vim.fn.getcwd())
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

--- Resolve the trash file path for an id or path the caller supplied.
--- @param id_or_path string Session id or a trash file path
--- @return string|nil path
--- @return string|nil err
local function resolve_trash_path(id_or_path)
  if type(id_or_path) ~= 'string' or id_or_path == '' then
    return nil, 'session id is required'
  end

  -- A full path (or anything ending in .json) is taken as-is. Session ids are
  -- timestamp strings (`YYYY-MM-DD-HH-MM-SS`) and never contain a separator.
  local looks_like_path = id_or_path:sub(-5) == '.json'
    or id_or_path:find('/', 1, true)
    or id_or_path:find('\\', 1, true)
  if looks_like_path then
    if vim.uv.fs_stat(id_or_path) then
      return id_or_path
    end
    return nil, 'trash file not found: ' .. id_or_path
  end

  -- Otherwise it is an id: newest matching entry wins.
  for _, entry in ipairs(M.list_trash()) do
    if entry.id == id_or_path then
      return entry.path
    end
  end
  return nil, 'session not found in trash: ' .. id_or_path
end

--- Move a session cache file into the trash directory.
---
--- The payload is rewritten rather than moved byte for byte, so `deleted_at`
--- lands inside the JSON: loopback renames preserve mtime but not reliably
--- across filesystems, and the trash listing sorts by that timestamp.
---
--- The original cache file is only unlinked after the trash copy exists, so a
--- failed write can never lose the session.
---
--- Only the session cache file is moved. Memories, scheduled tasks and bridged
--- integrations are still cleaned up by `sessions.delete()`: the trash protects
--- the conversation itself, nothing that belongs to other subsystems.
---
--- @param session_id string Session identifier
--- @param data? table Session payload to persist (receives `deleted_at`)
--- @return string|nil trash_path The file now holding the session
--- @return string|nil err Error message on failure
function M.move_to_trash(session_id, data)
  if type(session_id) ~= 'string' or session_id == '' then
    return nil, 'session id is required'
  end

  local src = M.cache_dir .. session_id .. '.json'
  if not vim.uv.fs_stat(src) then
    return nil, 'session cache file not found'
  end

  pcall(vim.fn.mkdir, M.trash_dir, 'p')
  if vim.fn.isdirectory(M.trash_dir) == 0 then
    return nil, 'failed to create trash directory: ' .. M.trash_dir
  end

  -- A session can be deleted, restored and deleted again, so the same id may
  -- already be in the trash. Suffix instead of overwriting: the older snapshot
  -- is the one the user might still want back.
  --
  -- The suffix is `~N`, not `-N`: session ids are timestamps and already end
  -- in `-<seconds>`, so `%-%d+$` would turn `2026-02-14-10-30-00` into
  -- `2026-02-14-10-30` when the id is recovered from the file name later.
  -- A tilde never appears in a session id.
  local target = M.trash_dir .. session_id .. '.json'
  local suffix = 0
  while vim.uv.fs_stat(target) do
    suffix = suffix + 1
    target = M.trash_dir .. session_id .. '~' .. suffix .. '.json'
  end

  local function write_target(content)
    local file = io.open(target, 'w')
    if not file then
      return false, 'failed to open trash file: ' .. target
    end
    local wrote, write_err = pcall(function()
      file:write(content)
      file:close()
    end)
    if not wrote then
      pcall(file.close, file)
      pcall(vim.fn.delete, target)
      return false, 'failed to write trash file: ' .. tostring(write_err)
    end
    return true
  end

  if data then
    local payload = vim.deepcopy(data)
    payload.deleted_at = os.time()
    local encoded_ok, encoded = pcall(vim.json.encode, payload)
    if not encoded_ok then
      return nil, 'failed to encode session: ' .. tostring(encoded)
    end
    local wrote, write_err = write_target(encoded)
    if not wrote then
      return nil, write_err
    end
  else
    local renamed = vim.uv.fs_rename(src, target)
    if not renamed then
      -- No payload and no rename support (or cross-device): copy, then unlink.
      local read = io.open(src, 'r')
      if not read then
        return nil, 'failed to read session cache file'
      end
      local content = read:read('*a')
      read:close()
      local wrote, write_err = write_target(content)
      if not wrote then
        return nil, write_err
      end
    end
  end

  vim.fn.delete(src)
  return target
end

--- Read a trashed session payload.
--- @param path string Trash file path
--- @return table|nil payload
function M.read_trash(path)
  local file = io.open(path, 'r')
  if not file then
    return nil
  end
  local content = file:read('*a')
  file:close()
  local ok, obj = pcall(vim.json.decode, content)
  if not ok or obj == vim.NIL or type(obj) ~= 'table' then
    return nil
  end
  return obj
end

--- First non-empty line of a session payload, used as a one-line preview.
--- @param payload table|nil Session payload
--- @return string|nil
local function first_non_empty_line(payload)
  if not payload or type(payload.messages) ~= 'table' then
    return nil
  end
  for _, m in ipairs(payload.messages) do
    if type(m.content) == 'string' then
      for _, line in ipairs(vim.split(m.content, '\n')) do
        if line ~= '' then
          return line
        end
      end
    end
  end
  return nil
end

--- List trashed sessions, newest deletion first.
---
--- Each entry reports the *session* id (collision suffixes stripped), so a
--- re-deleted session can be restored by the id the user knows.
---
--- @return table[] entries { id, path, deleted_at, title, preview, message_count }
function M.list_trash()
  if vim.fn.isdirectory(M.trash_dir) == 0 then
    return {}
  end

  local files = vim.fn.globpath(M.trash_dir, '*.json', false, true)
  local entries = {}
  for _, path in ipairs(files) do
    -- `id-1.json` is a collision suffix, not part of the session id.
    local id = vim.fn.fnamemodify(path, ':t:r'):gsub('~%d+$', '')
    local payload = M.read_trash(path)
    local deleted_at, title, message_count, preview
    if payload then
      deleted_at = payload.deleted_at
      title = payload.title
      preview = first_non_empty_line(payload)
      message_count = type(payload.messages) == 'table'
          and #payload.messages
        or 0
      if type(payload.id) == 'string' and payload.id ~= '' then
        id = payload.id
      end
    end
    if not deleted_at then
      local stat = vim.uv.fs_stat(path)
      deleted_at = stat and stat.mtime.sec or 0
    end
    table.insert(entries, {
      id = id,
      path = path,
      deleted_at = deleted_at,
      title = title,
      preview = preview,
      message_count = message_count or 0,
    })
  end

  table.sort(entries, function(a, b)
    if a.deleted_at == b.deleted_at then
      return a.id > b.id
    end
    return a.deleted_at > b.deleted_at
  end)
  return entries
end

--- Restore a trashed session back into the active cache directory.
---
--- The original id is kept, so a live session with the same id blocks the
--- restore with an error instead of being silently overwritten. On success the
--- session is loaded into memory, so the caller can switch to it right away.
---
--- @param id_or_path string Session id or trash file path
--- @return string|nil session_id The restored session id
--- @return string|nil err Error message on failure
function M.restore(id_or_path)
  local path, err = resolve_trash_path(id_or_path)
  if not path then
    return nil, err
  end

  local payload = M.read_trash(path)
  if not payload then
    return nil, 'invalid trash file: ' .. path
  end
  if not payload.messages then
    return nil, 'invalid session: missing messages'
  end

  local id = payload.id
  if type(id) ~= 'string' or id == '' then
    id = vim.fn.fnamemodify(path, ':t:r'):gsub('~%d+$', '')
    payload.id = id
  end

  local target = M.cache_dir .. id .. '.json'
  if M.sessions[id] or vim.uv.fs_stat(target) then
    return nil, 'session already exists: ' .. id
  end

  pcall(vim.fn.mkdir, M.cache_dir, 'p')
  if vim.fn.isdirectory(M.cache_dir) == 0 then
    return nil, 'failed to create cache directory: ' .. M.cache_dir
  end

  -- The session is live again, so the deletion marker has to go: the field
  -- only exists to sort and display the trash listing.
  payload.deleted_at = nil

  -- Fill in the fields a partially written payload could be missing, so the
  -- restored session behaves like one loaded from a regular cache file.
  if not payload.cwd then
    payload.cwd = vim.fs.normalize(vim.fn.getcwd())
  end
  if not payload.prompt then
    payload.prompt = get_config_system_prompt()
  end

  local file = io.open(target, 'w')
  if not file then
    return nil, 'failed to open cache file: ' .. target
  end
  local wrote, write_err = pcall(function()
    file:write(vim.json.encode(payload))
    file:close()
  end)
  if not wrote then
    pcall(file.close, file)
    pcall(vim.fn.delete, target)
    return nil, 'failed to write cache file: ' .. tostring(write_err)
  end

  vim.fn.delete(path)

  -- Load it into memory now: the caller usually switches to it immediately,
  -- and the window reads from `M.sessions`, not from disk.
  for _ in M.iter_sessions() do
  end

  return id
end

--- Permanently delete a trashed session.
--- @param id_or_path string Session id or trash file path
--- @return boolean True when the file is gone
--- @return string|nil err Error message on failure
function M.purge_trash(id_or_path)
  local path, err = resolve_trash_path(id_or_path)
  if not path then
    return false, err
  end
  local ok, delete_err = pcall(vim.fn.delete, path)
  if not ok then
    return false, 'failed to delete trash file: ' .. tostring(delete_err)
  end
  return true
end

return M

