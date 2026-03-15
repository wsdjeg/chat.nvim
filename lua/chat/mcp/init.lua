local M = {}

local log = require('chat.log')
local config = require('chat.config')
local transport = require('chat.mcp.transport')

---@class MCPServer
---@field transport table
---@field transport_type string
---@field tools MCPTool[]
---@field resources MCPResource[]

---@class MCPTool
---@field name string
---@field description string
---@field inputSchema table

local servers = {} ---@type table<string, MCPServer>
local request_id = 0
local pending_requests = {}

function M.setup()
  -- 注册内置 transport
  transport.register('stdio', require('chat.mcp.transport.stdio'))
  transport.register(
    'streamable_http',
    require('chat.mcp.transport.streamable_http')
  )

  -- 添加清理自动命令
  vim.api.nvim_create_autocmd('VimLeavePre', {
    callback = function()
      M.stop()
    end,
  })
end

-- 连接所有 MCP servers
function M.connect()
  local mcp_config = config.config.mcp or {}
  local servers_config = mcp_config.mcpServers or mcp_config

  for server_name, server_config in pairs(servers_config) do
    if not server_config.disabled and not servers[server_name] then
      M.connect_server(server_name, server_config)
    end
  end
end

-- 检测 transport 类型
local function detect_transport_type(server_config)
  local t = nil

  -- 如果有 transport.type，优先使用
  if server_config.transport and server_config.transport.type then
    t = server_config.transport.type
  -- 旧格式: command 存在但没有 transport，则是 stdio
  elseif server_config.command and not server_config.transport then
    return 'stdio'
  -- 只有 url，默认 streamable_http
  elseif server_config.url then
    return 'streamable_http'
  else
    return nil
  end

  -- 统一转换成 snake_case
  t = t:gsub('-', '_')
  t = t:gsub('([a-z])([A-Z])', '%1_%2')
  t = t:lower()

  return t
end

function M.remove_server(server_name)
  local server = servers[server_name]
  if server then
    servers[server_name] = nil
    log.info('[MCP] Removed disconnected server: ' .. server_name)
  end
end

local function get_transport_config(
  server_config,
  transport_type,
  server_name
)
  local base_config = {}

  if transport_type == 'stdio' then
    base_config = {
      command = server_config.command,
      args = server_config.args,
      env = server_config.env,
    }
  elseif transport_type == 'streamable_http' or transport_type == 'sse' then
    base_config = {
      command = server_config.command,
      args = server_config.args,
      env = server_config.env,
      url = server_config.transport and server_config.transport.url
        or server_config.url,
      headers = server_config.transport and server_config.transport.headers
        or server_config.headers,
    }
  end

  base_config.on_disconnect = function()
    M.remove_server(server_name)
  end

  return base_config
end

-- 连接到 MCP server
function M.connect_server(name, server_config)
  local transport_type = detect_transport_type(server_config)

  if not transport_type then
    log.error('[MCP:' .. name .. '] Unknown transport configuration')
    return
  end

  local transport_module = transport.get(transport_type)

  if not transport_module then
    log.error('[MCP:' .. name .. '] Transport not found: ' .. transport_type)
    return
  end

  local transport_config =
    get_transport_config(server_config, transport_type, name)

  local t, err = transport_module.create(name, transport_config, function(msg)
    M.handle_message(name, msg)
  end)

  if not t then
    log.error(
      '[MCP:'
        .. name
        .. '] Failed to create transport: '
        .. (err or 'unknown')
    )
    return
  end

  servers[name] = {
    transport = t,
    transport_type = transport_type,
    tools = {},
    resources = {},
  }

  -- 发送 initialize 请求
  -- 如果有 jobid，说明需要等待进程启动
  local init_delay = t.jobid and 8000 or 0

  local function send_initialize()
    M.send_request(name, 'initialize', {
      protocolVersion = '2024-11-05',
      capabilities = vim.empty_dict(),
      clientInfo = {
        name = 'chat.nvim',
        version = '1.0.0',
      },
    }, function(result)
      -- 发送 initialized 通知（MCP 协议要求）
      M.send_notification(name, 'initialized', vim.empty_dict())

      -- 延迟后请求工具列表
      vim.defer_fn(function()
        M.send_request(
          name,
          'tools/list',
          vim.empty_dict(),
          function(list_result)
            if list_result and list_result.tools then
              servers[name].tools = list_result.tools
              log.info(
                '[MCP:'
                  .. name
                  .. '] Registered '
                  .. #list_result.tools
                  .. ' tools'
              )
            else
              log.warn('[MCP:' .. name .. '] No tools found')
            end
          end
        )
      end, 100)
    end)
  end

  if init_delay > 0 then
    log.info(
      '[MCP] Waiting ' .. init_delay .. 'ms for server to start: ' .. name
    )
    vim.defer_fn(send_initialize, init_delay)
  else
    send_initialize()
  end

  log.info(
    '[MCP] Connected to server: ' .. name .. ' (' .. transport_type .. ')'
  )
end

-- 发送 JSON-RPC 请求
function M.send_request(server_name, method, params, callback)
  local server = servers[server_name]
  if not server then
    log.error('[MCP] Server not found: ' .. server_name)
    return nil, 'Server not found'
  end

  request_id = request_id + 1
  local id = request_id

  if callback then
    pending_requests[id] = {
      server = server_name,
      callback = callback,
    }
  end

  local request = vim.json.encode({
    jsonrpc = '2.0',
    id = id,
    method = method,
    params = params or vim.empty_dict(),
  }) .. '\n'

  local transport_module = transport.get(server.transport_type)
  if transport_module and transport_module.send then
    transport_module.send(server.transport, request)
  end

  return id
end

-- 发送 JSON-RPC 通知（无需响应）
function M.send_notification(server_name, method, params)
  local server = servers[server_name]
  if not server then
    log.error('[MCP] Server not found: ' .. server_name)
    return
  end

  local notification = vim.json.encode({
    jsonrpc = '2.0',
    method = method,
    params = params or vim.empty_dict(),
  }) .. '\n'

  local transport_module = transport.get(server.transport_type)
  if transport_module and transport_module.send then
    transport_module.send(server.transport, notification)
  end
end

-- 处理 JSON-RPC 消息
function M.handle_message(server_name, msg)
  -- Response
  if msg.id and pending_requests[msg.id] then
    local request = pending_requests[msg.id]
    pending_requests[msg.id] = nil

    if msg.result and request.callback then
      request.callback(msg.result)
    elseif msg.error then
      log.error(
        '[MCP:'
          .. server_name
          .. '] Request error: '
          .. (msg.error.message or 'unknown')
      )
    end

  -- Notification
  elseif msg.method then
    log.debug('[MCP:' .. server_name .. '] Notification: ' .. msg.method)
  end
end

-- 辅助函数：从已注册的 tools 中查找服务器名
-- 解决服务器名包含下划线的问题（如 open_webSearch）
local function find_server_for_tool(full_tool_name)
  -- 方案1：从已注册的 tools 列表中查找（最准确）
  for server_name, server in pairs(servers) do
    for _, mcp_tool in ipairs(server.tools) do
      if full_tool_name == 'mcp_' .. server_name .. '_' .. mcp_tool.name then
        return server_name, mcp_tool.name
      end
    end
  end

  -- 方案2：从末尾解析最后一个下划线（备选方案，兼容未来可能的格式变化）
  -- mcp_open_webSearch_search -> server: "open_webSearch", tool: "search"
  -- 使用贪婪匹配，server_name 匹配尽可能多的内容
  local server_name, mcp_tool_name = full_tool_name:match('^mcp_(.+)_(.-)$')
  if server_name and mcp_tool_name then
    -- 验证服务器是否存在
    if servers[server_name] then
      return server_name, mcp_tool_name
    end
  end

  return nil, nil
end

-- 调用 MCP tool
function M.call_tool(tool_name, arguments, ctx)
  -- 查找 server 名称和 tool 名称
  local server_name, mcp_tool_name = find_server_for_tool(tool_name)

  if not server_name or not mcp_tool_name then
    return { error = 'Invalid MCP tool name format: ' .. tool_name }
  end

  local server = servers[server_name]
  if not server then
    return { error = 'MCP server not found: ' .. server_name }
  end

  -- 发送 tools/call 请求（异步）
  local co = coroutine.running()
  local result_received = false
  local tool_result = nil

  M.send_request(server_name, 'tools/call', {
    name = mcp_tool_name,
    arguments = arguments,
  }, function(result)
    result_received = true
    tool_result = result
    if co then
      coroutine.resume(co)
    end
  end)

  -- 如果在协程中，等待结果
  if co then
    coroutine.yield()
  else
    -- 同步等待（使用 vim.wait）
    vim.wait(30000, function()
      return result_received
    end, 100)
  end

  if not tool_result then
    return { error = 'MCP tool call timeout or failed' }
  end

  -- 处理 MCP tool 结果格式
  if tool_result.content then
    local content_parts = {}
    for _, part in ipairs(tool_result.content) do
      if part.type == 'text' then
        table.insert(content_parts, part.text)
      end
    end
    return {
      content = table.concat(content_parts, '\n'),
    }
  elseif tool_result.isError then
    return {
      error = tool_result.isError or 'MCP tool call failed',
    }
  else
    return { content = vim.inspect(tool_result) }
  end
end

-- 获取所有 MCP tools（转换为 chat.nvim 格式）
function M.available_tools()
  local tools = {}

  for server_name, server in pairs(servers) do
    for _, mcp_tool in ipairs(server.tools) do
      table.insert(tools, {
        type = 'function',
        ['function'] = {
          name = 'mcp_' .. server_name .. '_' .. mcp_tool.name,
          description = '[MCP:'
            .. server_name
            .. '] '
            .. mcp_tool.description,
          parameters = mcp_tool.inputSchema,
        },
      })
    end
  end

  return tools
end

-- 检查是否是 MCP tool
function M.is_mcp_tool(tool_name)
  return tool_name:match('^mcp_[^_]+_.+$') ~= nil
end

-- 获取 MCP tool 的信息描述
function M.tool_info(tool_name, arguments_str)
  -- 查找 server 名称和 tool 名称
  local server_name, mcp_tool_name = find_server_for_tool(tool_name)

  if not server_name or not mcp_tool_name then
    return tool_name
  end

  -- 尝试解析 arguments JSON
  local args_info = ''
  local ok, arguments = pcall(vim.json.decode, arguments_str or '{}')
  if ok and arguments then
    -- 简单显示关键参数
    local parts = {}
    for key, value in pairs(arguments) do
      if type(value) == 'string' then
        table.insert(parts, string.format('%s="%s"', key, value))
      elseif type(value) == 'number' or type(value) == 'boolean' then
        table.insert(parts, string.format('%s=%s', key, value))
      end
    end
    if #parts > 0 then
      args_info = ' ' .. table.concat(parts, ' ')
    end
  end

  return string.format('mcp_%s_%s%s', server_name, mcp_tool_name, args_info)
end
-- 停止所有 servers
function M.stop()
  for name, server in pairs(servers) do
    local transport_module = transport.get(server.transport_type)
    if transport_module and transport_module.close then
      log.info('[MCP] Stopping server: ' .. name)
      transport_module.close(server.transport)
    end
  end
  servers = {}
end

return M
