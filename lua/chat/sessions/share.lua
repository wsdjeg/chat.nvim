-- Session share, import, and export
local M = {}

local log = require('chat.log')
local job = require('job')
local storage = require('chat.sessions.storage')

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

--- Saves a session to a JSON file at the specified path
--- Creates parent directories if they don't exist
--- @param session_id string The session identifier to save
--- @param filepath string The file path to save the session to
--- @return boolean True if saved successfully, false otherwise
function M.save_to_file(session_id, filepath)
  if not storage.sessions[session_id] then
    log.error('Session does not exist: ' .. session_id)
    return false
  end

  filepath = vim.fs.normalize(vim.fn.fnamemodify(filepath, ':p'))

  -- Ensure parent directory exists
  local dir = vim.fn.fnamemodify(filepath, ':h')
  if vim.fn.isdirectory(dir) == 0 then
    local ok, err = pcall(vim.fn.mkdir, dir, 'p')
    if not ok then
      log.error('Failed to create directory: ' .. err)
      return false
    end
  end

  local file = io.open(filepath, 'w')
  if not file then
    log.error('Failed to open file: ' .. filepath)
    return false
  end

  local success, err = pcall(function()
    file:write(vim.json.encode(storage.sessions[session_id]))
    io.close(file)
  end)

  if not success then
    log.error('Failed to write session: ' .. err)
    return false
  end

  log.notify('Session saved to:\n' .. filepath)
  return true
end

--- Loads a session from a JSON file at the specified path
--- Generates a new session ID if the original ID already exists
--- @param filepath string The file path to load the session from
--- @return string|nil The loaded session ID if successful, nil otherwise
function M.load_from_file(filepath)
  filepath = vim.fs.normalize(vim.fn.fnamemodify(filepath, ':p'))

  if vim.fn.filereadable(filepath) == 0 then
    log.error('File not found: ' .. filepath)
    return nil
  end

  local file = io.open(filepath, 'r')
  if not file then
    log.error('Failed to open file: ' .. filepath)
    return nil
  end

  local content = file:read('*a')
  io.close(file)

  local ok, obj = pcall(vim.json.decode, content)
  if not ok or obj == vim.NIL then
    log.error('Invalid session file format: ' .. filepath)
    return nil
  end

  if not obj.messages or type(obj.messages) ~= 'table' then
    log.error('Invalid session: missing messages')
    return nil
  end

  -- Generate new session ID if already exists
  local session_id = obj.id
  if not session_id or storage.sessions[session_id] then
    session_id = os.date('%Y-%m-%d-%H-%M-%S', os.time())
    obj.id = session_id
  end

  local config = require('chat.config')
  obj.provider = obj.provider or config.config.provider
  obj.model = obj.model or config.config.model
  obj.cwd = obj.cwd or vim.fs.normalize(vim.fn.getcwd())
  obj.prompt = obj.prompt or get_config_system_prompt()

  storage.sessions[session_id] = obj
  require('chat.sessions.storage').write_cache(session_id)

  log.notify('Session loaded: ' .. session_id)
  return session_id
end

--- Shares a session to pastebin (paste.rs) and returns the URL
--- The URL is copied to clipboard for easy sharing
--- @param session_id string The session identifier to share
--- @return nil Returns nil, URL is displayed and copied to clipboard
function M.share(session_id)
  if not storage.sessions[session_id] then
    log.error('Session does not exist: ' .. session_id)
    return nil
  end

  local content = vim.json.encode(storage.sessions[session_id])
  local url = 'https://paste.rs'

  local stdout = {}
  local stderr = {}

  local jobid = job.start({
    'curl',
    '-s',
    '-w',
    '\n%{http_code}',
    '--data-binary',
    '@-',
    url,
  }, {
    on_stdout = function(id, data)
      for _, v in ipairs(data) do
        table.insert(stdout, v)
      end
    end,
    on_stderr = function(id, data)
      for _, v in ipairs(data) do
        table.insert(stderr, v)
      end
    end,
    on_exit = function(id, code, single)
      if code == 0 and single == 0 then
        local output = table.concat(stdout, '\n')
        local result, http_code = output:match('^(.-)\n(%d+)$')

        if
          http_code
          and tonumber(http_code) >= 200
          and tonumber(http_code) < 300
        then
          result = vim.trim(result)
          vim.fn.setreg('+', result)
          log.notify(
            '✓ Session shared!\nURL: '
              .. result
              .. '\n(Copied to clipboard)'
          )
        else
          log.error(
            'Failed to share session (HTTP '
              .. (http_code or 'unknown')
              .. '): '
              .. (result or output)
          )
          log.notify(
            '✗ Failed to share session\nCheck chat.nvim runtime log',
            'ErrorMsg'
          )
        end
      else
        log.error(
          'Failed to share session: '
            .. (table.concat(stderr, '\n') or 'unknown error')
        )
        log.notify(
          '✗ Failed to share session\nCheck chat.nvim runtime log',
          'ErrorMsg'
        )
      end
    end,
  })
  job.send(jobid, content)
  job.send(jobid, nil)
end

--- Loads a session from a URL containing session JSON data
--- Fetches the content via HTTP and creates a new session
--- @param url string The URL to fetch the session from (must start with http:// or https://)
--- @return string|nil The loaded session ID if successful, nil otherwise
function M.load_from_url(url)
  if not url:match('^https?://') then
    log.error('Invalid URL, must start with http:// or https://')
    return
  end

  local result
  local ok, err

  if vim.fn.has('nvim-0.10') == 1 then
    local obj = vim
      .system({
        'curl',
        '-s',
        '-L',
        url,
      }, { text = true })
      :wait()

    ok = obj.code == 0
    if ok then
      result = obj.stdout
    else
      err = obj.stderr
    end
  else
    local cmd = string.format('curl -s -L %s', vim.fn.shellescape(url))
    result = vim.fn.system(cmd)
    ok = vim.v.shell_error == 0
    err = result
  end

  if not ok or not result or result == '' then
    log.error('Failed to load from URL: ' .. (err or 'unknown error'))
    return
  end

  local obj
  ok, err = pcall(vim.json.decode, result)
  if not ok or err == vim.NIL then
    log.error('Invalid session data from URL')
    return
  end
  obj = err

  if not obj.messages or type(obj.messages) ~= 'table' then
    log.error('Invalid session: missing messages')
    return
  end

  local session_id = obj.id
  if not session_id or storage.sessions[session_id] then
    session_id = os.date('%Y-%m-%d-%H-%M-%S', os.time())
    obj.id = session_id
  end

  local config = require('chat.config')
  obj.provider = obj.provider or config.config.provider
  obj.model = obj.model or config.config.model
  obj.cwd = obj.cwd or vim.fs.normalize(vim.fn.getcwd())
  obj.prompt = obj.prompt or get_config_system_prompt()

  storage.sessions[session_id] = obj
  require('chat.sessions.storage').write_cache(session_id)

  log.notify('Session loaded from URL: ' .. session_id)
  return session_id
end

return M
