local M = {}

local log = require('chat.log')
local job = require('job')

---@class StreamableHttpTransport
---@field url string
---@field server_name string
---@field on_message function
---@field session_id string|nil
---@field headers table
---@field jobid number|nil

function M.create(server_name, config, on_message)
  if not config.url then
    return nil, 'streamable_http transport requires "url" field'
  end

  local transport = {
    type = 'streamable_http',
    url = config.url,
    headers = config.headers or {},
    server_name = server_name,
    on_message = on_message,
    session_id = nil,
    jobid = nil,
  }

  -- 如果有 command，先启动进程
  if config.command then
    local cmd = { config.command }
    if config.args then
      vim.list_extend(cmd, config.args)
    end

    transport.jobid = job.start(cmd, {
      on_stdout = function(_, data)
        for _, v in ipairs(data) do
          if v and #v > 0 then
            log.debug('[MCP:' .. server_name .. '] ' .. v)
          end
        end
      end,
      on_stderr = function(_, data)
        for _, v in ipairs(data) do
          if v and #v > 0 then
            log.info('[MCP:' .. server_name .. '] ' .. v)
          end
        end
      end,
      on_exit = function(_, code, single)
        log.warn(
          '[MCP:' .. server_name .. '] Server exited with code ' .. code
        )
        transport.jobid = nil
        if config.on_disconnect then
          config.on_disconnect()
        end
      end,
      env = config.env,
    })

    if not transport.jobid or transport.jobid <= 0 then
      return nil, 'Failed to start server: ' .. server_name
    end

    log.info(
      '[MCP] Starting server: '
        .. server_name
        .. ' pid:'
        .. job.pid(transport.jobid)
    )
  end

  log.info(
    '[MCP] Connected to server via streamable_http: '
      .. server_name
      .. ' ('
      .. config.url
      .. ')'
  )
  return transport, nil
end

-- Send JSON-RPC message via HTTP POST
---@param transport table
---@param message string (already encoded JSON-RPC)
function M.send(transport, message)
  -- Remove trailing newline for HTTP
  message = message:gsub('\n$', '')

  local headers = {
    'Content-Type: application/json',
    'Accept: application/json, text/event-stream',
  }

  -- Add session ID if available
  if transport.session_id then
    table.insert(headers, 'Mcp-Session-Id: ' .. transport.session_id)
  end

  -- Add custom headers
  if transport.headers then
    for k, v in pairs(transport.headers) do
      table.insert(headers, k .. ': ' .. v)
    end
  end

  -- 使用 -i 来获取 response headers
  local cmd = { 'curl', '-s', '-i', '-X', 'POST' }

  -- 本地地址不走代理
  if
    transport.url:match('^https?://127%.0%.0%.1')
    or transport.url:match('^https?://localhost')
    or transport.url:match('^https?://[::1]')
  then
    table.insert(cmd, '--noproxy')
    table.insert(cmd, '*')
  end

  for _, h in ipairs(headers) do
    table.insert(cmd, '-H')
    table.insert(cmd, h)
  end

  table.insert(cmd, '-d')
  table.insert(cmd, message)
  table.insert(cmd, transport.url)

  job.start(cmd, {
    on_stdout = function(_, data)
      local response = table.concat(data, '\n')
      if response and #response > 0 then
        M._handle_response(transport, response)
      end
    end,
    on_stderr = function(_, data)
      for _, v in ipairs(data) do
        if v and #v > 0 then
          log.error('[MCP:' .. transport.server_name .. '] curl error: ' .. v)
        end
      end
    end,
    on_exit = function(_, code, single)
      if code ~= 0 or single ~= 0 then
        log.debug(
          '[MCP HTTP] send on_exit called, code: '
            .. code
            .. ' single: '
            .. single
        )
      end
    end,
  })
end

-- Handle HTTP response (with headers)
---@param transport table
---@param response string
function M._handle_response(transport, response)
  -- 分离 headers 和 body
  local header_end = response:find('\r\n\r\n') or response:find('\n\n')
  local headers_text = ''
  local body = response

  if header_end then
    headers_text = response:sub(1, header_end - 1)
    body = response:sub(header_end + 2):gsub('^[\r\n]+', '') -- 跳过空行
  end

  -- 解析 headers 获取 Mcp-Session-Id
  for line in headers_text:gmatch('[^\r\n]+') do
    local key, value = line:match('^(%S+):%s*(.+)$')
    if key and key:lower() == 'mcp-session-id' then
      -- 只在第一次收到 session ID 时打印
      if not transport.session_id then
        log.debug(
          '[MCP:' .. transport.server_name .. '] Session ID: ' .. value
        )
      end
      transport.session_id = value
    end
  end

  -- 解析 body
  if #body == 0 then
    return
  end

  -- Check if body is SSE format
  if body:match('^event:') or body:match('^data:') then
    -- Parse SSE stream
    for line in body:gmatch('[^\r\n]+') do
      local data = line:match('^data:%s*(.+)$')
      if data and data:sub(1, 1) == '{' then
        local ok, msg = pcall(vim.json.decode, data)
        if ok then
          transport.on_message(msg)
        end
      end
    end
  elseif body:sub(1, 1) == '{' then
    -- Regular JSON response
    local ok, msg = pcall(vim.json.decode, body)
    if ok then
      transport.on_message(msg)
    end
  elseif body:sub(1, 1) == '[' then
    -- Batch response
    local ok, arr = pcall(vim.json.decode, body)
    if ok and type(arr) == 'table' then
      for _, msg in ipairs(arr) do
        transport.on_message(msg)
      end
    end
  end
end

-- Close transport
---@param transport table
function M.close(transport)
  -- Local process: kill directly
  if transport.jobid then
    local root_pid = job.pid(transport.jobid)
    local function get_all_children(pid, pids)
      pids = pids or {}
      local children = vim.api.nvim_get_proc_children(pid)

      for _, child_pid in ipairs(children) do
        table.insert(pids, child_pid)
        get_all_children(child_pid, pids) -- 递归
      end

      return pids
    end

    -- 使用
    local pids = get_all_children(root_pid)
    if #pids > 0 then
      log.debug(
        '[MCP:'
          .. transport.server_name
          .. '] Cleaning up '
          .. ' processes (root: '
          .. root_pid
          .. ' child: '
          .. table.concat(pids, ', ')
          .. ')'
      )

      table.insert(pids, 1, root_pid)
      local signal = vim.fn.has('win32') == 1 and 'sigint' or 'sigterm'

      for _, v in ipairs(pids) do
        local code, err = vim.uv.kill(v, signal)
        if code ~= 0 then
          log.warn(
            '[MCP:'
              .. transport.server_name
              .. '] '
              .. 'Failed to kill PID '
              .. v
              .. '  code: '
              .. tostring(code)
              .. ' err: '
              .. tostring(err)
          )
        end
      end
    end
    transport.jobid = nil
    transport.session_id = nil
    return
  end

  -- Remote MCP: send DELETE to terminate session
  if transport.session_id then
    local cmd = { 'curl', '-s', '-X', 'DELETE' }
    table.insert(cmd, '-H')
    table.insert(cmd, 'Mcp-Session-Id: ' .. transport.session_id)
    table.insert(cmd, transport.url)

    job.start(cmd, {
      on_exit = function()
        log.debug('[MCP:' .. transport.server_name .. '] Session terminated')
      end,
    })
  end

  transport.session_id = nil
end

return M
